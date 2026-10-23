{ lib, ... }:

# KRunner aliases for the twelve ArtCraft Crafting Apps.
#
# The apps ship their own launcher entries (ai.storyteller.<app>) system-wide in
# /usr/share/applications. An entry declared here lands in
# ~/.local/share/applications under the *same* filename, and the launcher scans
# the user directory first — so this shadows the shipped entry rather than adding
# a duplicate icon, and makes each app searchable by both its Rust name and the
# Adobe-family name it stands in for:
#
#   photocraft       -> photoshop      vectorcraft -> illustrator
#   lightcraft       -> lightroom      designcraft -> indesign
#   filmcraft        -> premiere pro   effectcraft -> after effects
#   soundcraft       -> audition       pdfcraft    -> acrobat
#   gridcraft        -> excel          deckcraft   -> powerpoint
#   wordcraft        -> word           cadcraft    -> autocad
#
# Every other field mirrors the shipped entry (Exec, icon, MIME associations,
# StartupWMClass for window matching) so the shadow stays launchable and
# file-associable, not just searchable.

let
  # One row per app: the shipped entry, plus `alias` — the names appended to
  # Keywords. `startupNotify`, `tryExec` and `wm` carry only the exceptions to
  # what upstream ships (null = the shipped entry omits the key).
  apps = {
    cadcraft = {
      title = "CADCraft";
      genericName = "Computer-Aided Design";
      comment = "Draft, dimension and plot 2D drawings; open DXF and DWG files";
      categories = [ "Graphics" "Engineering" "VectorGraphics" ];
      mimeTypes = [ "image/vnd.dxf" "image/vnd.dwg" "application/x-dxf" "application/acad" ];
      keywords = [ "cad" "drafting" "dxf" "dwg" "drawing" "engineering" "architecture" "mechanical" ];
      alias = [ "autocad" "autodesk" ];
    };

    deckcraft = {
      title = "DeckCraft";
      genericName = "Presentation";
      comment = "Create and present slide decks";
      categories = [ "Office" "Presentation" ];
      mimeTypes = [
        "application/x-deckcraft"
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "application/vnd.openxmlformats-officedocument.presentationml.template"
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
      ];
      keywords = [ "presentation" "slides" "slide show" "deck" "pptx" "keynote" "powerpoint" ];
      alias = [ "powerpoint" "presentation" ];
    };

    designcraft = {
      title = "DesignCraft";
      genericName = "Page Layout";
      comment = "Lay out magazines, books and print documents";
      categories = [ "Graphics" "Publishing" ];
      keywords = [ "layout" "page" "desktop publishing" "dtp" "magazine" "book" "indesign" "idml" "typesetting" ];
      alias = [ "indesign" ];
    };

    effectcraft = {
      title = "EffectCraft";
      genericName = "Motion Graphics Editor";
      comment = "Motion graphics and visual effects compositor";
      categories = [ "AudioVideo" "Video" "Graphics" "2DGraphics" ];
      keywords = [ "motion" "graphics" "animation" "compositor" "effects" "keyframe" "vfx" ];
      alias = [ "after effects" "aftereffects" "ae" ];
    };

    filmcraft = {
      title = "FilmCraft";
      genericName = "Video Editor";
      comment = "Edit video, color and sound";
      categories = [ "AudioVideo" "Video" "AudioVideoEditing" ];
      keywords = [ "video" "editor" "film" "timeline" "color" "grading" "nle" ];
      alias = [ "premiere pro" "premiere" ];
    };

    gridcraft = {
      title = "GridCraft";
      genericName = "Spreadsheet";
      comment = "Calculate, analyse and chart data in workbooks";
      categories = [ "Office" "Spreadsheet" ];
      mimeTypes = [
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "application/vnd.ms-excel.sheet.macroEnabled.12"
        "text/csv"
        "text/tab-separated-values"
      ];
      keywords = [ "spreadsheet" "workbook" "sheet" "table" "formula" "chart" "pivot" "xlsx" "csv" "tsv" "excel" ];
      alias = [ "excel" ];
    };

    lightcraft = {
      title = "LightCraft";
      genericName = "Photo Library and Raw Developer";
      comment = "Organise photos and develop raw files, non-destructively";
      categories = [ "Graphics" "2DGraphics" "RasterGraphics" "Photography" ];
      mimeTypes = [
        "image/jpeg"
        "image/png"
        "image/tiff"
        "image/webp"
        "image/x-adobe-dng"
        "image/x-sony-arw"
        "image/x-canon-cr2"
        "image/x-canon-cr3"
        "image/x-nikon-nef"
        "image/x-fuji-raf"
        "image/x-olympus-orf"
        "image/x-panasonic-rw2"
        "image/x-panasonic-rw"
        "image/x-pentax-pef"
      ];
      keywords = [ "photo" "raw" "camera" "library" "develop" ];
      alias = [ "lightroom" ];
      # The shipped entry carries neither TryExec nor StartupNotify.
      startupNotify = null;
      tryExec = null;
    };

    pdfcraft = {
      title = "PdfCraft";
      genericName = "PDF Editor";
      comment = "Read, organize, combine, split and secure PDFs";
      exec = "pdfcraft %U";
      categories = [ "Office" "Viewer" ];
      mimeTypes = [ "application/pdf" ];
      keywords = [ "pdf" "viewer" "editor" "annotate" "sign" "forms" "merge" "split" ];
      alias = [ "acrobat" ];
      # Upstream's StartupWMClass is the bare app name here, not the entry id.
      wm = "pdfcraft";
    };

    photocraft = {
      title = "PhotoCraft";
      genericName = "Image Editor";
      comment = "Edit photos and layered PSD documents";
      categories = [ "Graphics" "2DGraphics" "RasterGraphics" "Photography" ];
      mimeTypes = [
        "application/x-photocraft"
        "image/x-paintnet"
        "image/vnd.adobe.photoshop"
        "image/x-psd"
        "image/x-psb"
        "image/png"
        "image/jpeg"
        "image/tiff"
        "image/webp"
        "image/gif"
        "image/bmp"
        "image/x-tga"
        "image/x-icon"
        "image/vnd.microsoft.icon"
        "image/x-portable-anymap"
        "image/x-portable-bitmap"
        "image/x-portable-graymap"
        "image/x-portable-pixmap"
        "image/x-exr"
        "image/vnd.radiance"
        "image/avif"
        "image/qoi"
      ];
      keywords = [ "photo" "image" "editor" "psd" "layers" "retouch" "paint" ];
      alias = [ "photoshop" "psd" ];
      # PhotoCraft's runner never completes the startup-notification handshake.
      startupNotify = false;
      wm = "photocraft";
    };

    soundcraft = {
      title = "SoundCraft";
      genericName = "Digital Audio Workstation";
      comment = "Record, edit and mix audio and MIDI";
      categories = [ "AudioVideo" "Audio" "Midi" "Mixer" "Sequencer" "Recorder" ];
      mimeTypes = [
        "application/x-soundcraft-session"
        "audio/x-wav"
        "audio/wav"
        "audio/vnd.wave"
        "audio/x-aiff"
        "audio/aiff"
        "audio/flac"
        "audio/x-flac"
        "audio/mpeg"
        "audio/midi"
        "audio/x-midi"
      ];
      keywords = [ "daw" "audio" "mixer" "recording" "multitrack" "midi" "editor" "music" ];
      alias = [ "audition" "adobe audition" ];
    };

    vectorcraft = {
      title = "VectorCraft";
      genericName = "Vector Graphics Editor";
      comment = "Draw and edit vector illustrations, SVG and PDF";
      categories = [ "Graphics" "2DGraphics" "VectorGraphics" ];
      mimeTypes = [ "image/svg+xml" "application/pdf" ];
      keywords = [ "vector" "illustration" "svg" "pdf" "drawing" "bezier" ];
      alias = [ "illustrator" ];
    };

    wordcraft = {
      title = "WordCraft";
      genericName = "Word Processor";
      comment = "Write and design documents; open and save Word files";
      categories = [ "Office" "WordProcessor" ];
      mimeTypes = [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "application/vnd.oasis.opendocument.text"
        "application/rtf"
        "text/markdown"
        "text/html"
        "text/plain"
      ];
      keywords = [ "word" "processor" "document" "docx" "writer" "text" "letter" "report" ];
      alias = [ "word" "microsoft word" ];
    };
  };

  # The entry builder: `name` is the app key, the entry id is the shipped
  # filename (ai.storyteller.<app>) so the shadow replaces that file rather than
  # adding a second launcher next to it.
  mkEntry = name: a: {
    name = a.title;
    inherit (a) genericName comment;
    exec = a.exec or "${name} %F";
    icon = "ai.storyteller.${name}";
    terminal = false;
    inherit (a) categories;
    mimeType = a.mimeTypes or null;
    startupNotify = a.startupNotify or true;
    settings = lib.filterAttrs (_n: v: v != null) {
      TryExec = a.tryExec or name;
      StartupWMClass = a.wm or "ai.storyteller.${name}";
      Keywords = lib.concatStringsSep ";" (lib.unique (a.keywords ++ a.alias));
    };
  };
in
{
  xdg.desktopEntries = builtins.listToAttrs (
    map
      (name: {
        name = "ai.storyteller.${name}";
        value = mkEntry name apps.${name};
      })
      (builtins.attrNames apps)
  );
}
