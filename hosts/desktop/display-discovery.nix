{ pkgs, ... }:

let
  display-discovery = pkgs.writeShellScriptBin "display-discovery" ''
    exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
    import glob
    import os
    import sys


    def edid_string(data, offset, length):
        """Decode an EDID ASCII descriptor, stripping padding/newlines."""
        raw = data[offset:offset + length]
        raw = raw.split(b"\n", 1)[0]
        raw = raw.split(b"\x00", 1)[0]
        return raw.decode("ascii", errors="replace").strip(" \r\n")


    def manufacturer(data):
        """Decode the 3-character EDID manufacturer ID."""
        value = (data[8] << 8) | data[9]

        chars = [
            (value >> 10) & 0x1f,
            (value >> 5) & 0x1f,
            value & 0x1f,
        ]

        if any(c < 1 or c > 26 for c in chars):
            return "UNKNOWN"

        return "".join(chr(ord("A") + c - 1) for c in chars)


    def parse_edid(data):
        if len(data) < 128:
            raise ValueError("EDID is shorter than 128 bytes")

        if data[0:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
            raise ValueError("invalid EDID header")

        # Base EDID checksum.
        if sum(data[0:128]) & 0xff:
            raise ValueError("invalid EDID checksum")

        mfr = manufacturer(data)

        # EDID descriptors live at 0x36, four 18-byte descriptors.
        product_name = None
        serial = None

        for i in range(4):
            off = 0x36 + i * 18
            descriptor = data[off:off + 18]

            if descriptor[0:2] != b"\x00\x00":
                continue

            tag = descriptor[3]

            if tag == 0xff:
                serial = edid_string(data, off + 5, 13)

            elif tag == 0xfc:
                product_name = edid_string(data, off + 5, 13)

        # EDID product code. Useful as a fallback/debug identifier.
        product_code = data[10] | (data[11] << 8)

        # EDID physical serial number, if present in the base block.
        edid_serial = (
            data[12]
            | (data[13] << 8)
            | (data[14] << 16)
            | (data[15] << 24)
        )

        return {
            "manufacturer": mfr,
            "model": product_name or "UNKNOWN",
            "serial": serial or "",
            "product_code": product_code,
            "edid_serial": edid_serial,
        }


    def connectors():
        # The class directory gives us the stable DRM connector namespace.
        # Do not assume card0/card1 or a particular PCI topology.
        for path in sorted(glob.glob("/sys/class/drm/card*-DP-*")):
            connector = os.path.basename(path)

            # Ignore things that aren't actual DRM connectors.
            status_path = os.path.join(path, "status")
            edid_path = os.path.join(path, "edid")

            try:
                with open(status_path) as f:
                    status = f.read().strip()
            except OSError:
                continue

            if status != "connected":
                continue

            try:
                with open(edid_path, "rb") as f:
                    data = f.read()
            except OSError:
                continue

            if not data:
                continue

            try:
                identity = parse_edid(data)
            except ValueError as e:
                print(
                    f"warning: could not parse EDID for {connector}: {e}",
                    file=sys.stderr,
                )
                continue

            yield {
                "connector": connector.removeprefix("card"),
                "drm_path": os.path.realpath(path),
                **identity,
            }


    for display in connectors():
        print(
            "{connector}: {manufacturer} {model}"
            .format(**display)
            + (
                f" (serial {display['serial']})"
                if display["serial"]
                else ""
            )
        )
    PY
  '';
in
{
  environment.systemPackages = [
    display-discovery
  ];
}