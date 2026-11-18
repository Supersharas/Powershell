
import csv
import html
import ntpath
import hashlib
from pathlib import Path
from datetime import datetime


# ============================================================
# CONFIGURATION
# ============================================================

INPUT_CSV = r"C:\Temp\RoboSizeReport\FolderSizes.csv"

PERMISSION_CSV = r"C:\Temp\RoboSizeReport\permission.csv"

OUTPUT_HTML = r"C:\Temp\RoboSizeReport\FolderSizes.html"


# ============================================================
# CSV READER - AUTOMATIC DELIMITER DETECTION
# ============================================================

def open_csv_reader(file):

    sample = file.read(8192)
    file.seek(0)

    try:
        dialect = csv.Sniffer().sniff(
            sample,
            delimiters=",;\t|"
        )
    except csv.Error:
        dialect = csv.excel

    return csv.DictReader(file, dialect=dialect)


# ============================================================
# PATH NORMALISATION
# ============================================================

def normalise_path(path):

    if not path:
        return ""

    return ntpath.normpath(path.strip()).casefold()


# ============================================================
# READ PERMISSIONS CSV
# ============================================================

def read_permissions(permission_file):

    permissions = {}

    print("Reading permissions CSV...")

    with open(
        permission_file,
        "r",
        encoding="utf-8-sig",
        newline=""
    ) as file:

        reader = open_csv_reader(file)

        required_columns = {
            "Path",
            "Status",
            "Owner",
            "AllPermissions",
            "Error"
        }

        if not required_columns.issubset(reader.fieldnames or []):

            raise ValueError(
                "Permission CSV is missing required columns: "
                + ", ".join(sorted(required_columns))
            )

        for row in reader:

            folder_path = row.get("Path", "").strip()

            if not folder_path:
                continue

            path_key = normalise_path(folder_path)

            permissions[path_key] = {

                "status": row.get("Status", "").strip(),

                "owner": row.get("Owner", "").strip(),

                "all_permissions": row.get(
                    "AllPermissions", ""
                ).strip(),

                "error": row.get("Error", "").strip()

            }

    print(f"Folders with permission records: {len(permissions)}")

    error_count = sum(
        1 for item in permissions.values()
        if item["error"] and item["error"].casefold() not in ("none", "null")
    )

    print(f"Folders with permission errors: {error_count}")

    return permissions


# ============================================================
# PARSE INDIVIDUAL PERMISSIONS
# ============================================================

def parse_permission_entries(permission_string):

    if not permission_string:
        return []

    entries = []

    # Each permission entry is separated by |
    for item in permission_string.split("|"):

        item = item.strip()

        if not item:
            continue

        identity = item
        permission = "Unknown"
        additional = []

        # Expected format:
        # DOMAIN\Group (Modify, Synchronize, Explicit)

        if " (" in item and item.endswith(")"):

            identity, details = item.rsplit(" (", 1)

            identity = identity.strip()

            details = details[:-1]

            parts = [
                part.strip()
                for part in details.split(",")
                if part.strip()
            ]

            if parts:

                permission = parts[0]

                additional = parts[1:]

        entries.append({

            "identity": identity,

            "permission": permission,

            "additional": additional

        })

    return entries


# ============================================================
# READ FOLDER SIZE CSV AND BUILD TREE
# ============================================================

def read_csv(csv_file, permissions):

    folders = {}

    print("Reading folder size CSV...")

    with open(
        csv_file,
        "r",
        encoding="utf-8-sig",
        newline=""
    ) as file:

        reader = open_csv_reader(file)

        for row in reader:

            full_path = row.get("FullPath", "").strip()

            if not full_path:
                continue

            path_key = normalise_path(full_path)

            if path_key in folders:
                continue

            parent_path = row.get("ParentPath", "").strip()

            folders[path_key] = {

                "name": row.get(
                    "Name", ntpath.basename(full_path)
                ),

                "path": full_path,

                "parent_key": normalise_path(parent_path),

                "size": row.get("Size", ""),

                "size_bytes": row.get("SizeBytes", "0"),

                "file_count": row.get("FileCount", "0"),

                "dir_count": row.get("DirCount", "0"),

                "status": row.get("ScanStatus", "Unknown"),

                "permissions": permissions.get(path_key),

                "children": []

            }

    # Build folder hierarchy

    roots = []

    for key, folder in folders.items():

        parent_key = folder["parent_key"]

        if parent_key in folders and parent_key != key:

            folders[parent_key]["children"].append(folder)

        else:

            roots.append(folder)

    print(f"Folders discovered: {len(folders)}")

    matched = sum(
        1 for folder in folders.values()
        if folder["permissions"] is not None
    )

    unmatched = len(permissions) - matched

    print(f"Folders matched with permissions: {matched}")
    print(f"Permission records without folder-size match: {unmatched}")

    return roots


# ============================================================
# FORMAT SIZE
# ============================================================

def format_size(folder):

    if folder["size"]:
        return folder["size"]

    try:
        size_bytes = int(folder["size_bytes"])
    except (ValueError, TypeError):
        return "Unknown"

    units = ["Bytes", "KB", "MB", "GB", "TB"]

    value = float(size_bytes)

    for unit in units:

        if value < 1024 or unit == "TB":
            return f"{value:,.2f} {unit}"

        value /= 1024

    return f"{value:,.2f} TB"


# ============================================================
# CREATE UNIQUE HTML ELEMENT ID
# ============================================================

def make_element_id(path, element_type):

    value = path + "_" + element_type

    return element_type + "-" + hashlib.md5(
        value.encode("utf-8")
    ).hexdigest()


# ============================================================
# RENDER EXPANDABLE INFORMATION BUTTON
# ============================================================

def render_info_button(path, label, content, button_class):

    if not content:
        return ""

    element_id = make_element_id(path, button_class)

    safe_id = html.escape(element_id, quote=True)

    return f"""
    <button
        type="button"
        class="info-toggle {button_class}"
        onclick="togglePanel(event, '{safe_id}')"
    >
        {label}
    </button>

    <div
        class="info-panel"
        id="{safe_id}"
        hidden
    >
        {content}
    </div>
    """


# ============================================================
# RENDER OWNER
# ============================================================

def render_owner(folder):

    acl = folder["permissions"]

    if not acl:
        return ""

    owner = acl["owner"]

    if not owner:
        return ""

    content = f"""
    <div class="owner-content">
        <strong>Folder owner:</strong>
        <span>{html.escape(owner)}</span>
    </div>
    """

    return render_info_button(
        folder["path"],
        "👤 Owner",
        content,
        "owner-button"
    )


# ============================================================
# RENDER PERMISSIONS
# ============================================================

def render_permissions(folder):

    acl = folder["permissions"]

    if not acl:
        return ""

    entries = parse_permission_entries(
        acl["all_permissions"]
    )

    if not entries:
        return ""

    rows = ""

    for entry in entries:

        identity = html.escape(entry["identity"])

        permission = html.escape(entry["permission"])

        additional = ""

        for item in entry["additional"]:

            item_class = (
                "explicit"
                if item.casefold() == "explicit"
                else "inherited"
                if item.casefold() == "inherited"
                else "permission-detail"
            )

            additional += f"""
            <span class="permission-detail {item_class}">
                {html.escape(item)}
            </span>
            """

        permission_class = (
            "full-control"
            if permission.casefold() == "fullcontrol"
            else "modify"
            if permission.casefold() == "modify"
            else "read"
            if permission.casefold() in (
                "read",
                "readandexecute",
                "listfoldercontents"
            )
            else "other-permission"
        )

        rows += f"""
        <tr>

            <td class="identity-cell">
                {identity}
            </td>

            <td>
                <span class="permission-level {permission_class}">
                    {permission}
                </span>
                {additional}
            </td>

        </tr>
        """

    content = f"""
    <table class="permissions-table">

        <thead>
            <tr>
                <th>Identity / Group</th>
                <th>Permission level</th>
            </tr>
        </thead>

        <tbody>
            {rows}
        </tbody>

    </table>
    """

    return render_info_button(
        folder["path"],
        f"🔐 Permissions ({len(entries)})",
        content,
        "permissions-button"
    )


# ============================================================
# RENDER ERRORS
# ============================================================

def render_errors(folder):

    acl = folder["permissions"]

    if not acl:
        return ""

    error = acl["error"]

    if not error or error.casefold() in ("none", "null"):
        return ""

    content = f"""
    <div class="error-content">
        <strong>Permission scan error:</strong>
        <p>{html.escape(error)}</p>
    </div>
    """

    return render_info_button(
        folder["path"],
        "⚠ Error",
        content,
        "error-button"
    )


# ============================================================
# RENDER PERMISSION STATUS
# ============================================================

def render_acl_status(folder):

    acl = folder["permissions"]

    if not acl or not acl["status"]:
        return ""

    status = html.escape(acl["status"])

    return f"""
    <span class="acl-status">
        {status}
    </span>
    """


# ============================================================
# RENDER ALL FOLDER PERMISSION CONTROLS
# ============================================================

def render_folder_permissions(folder):

    if not folder["permissions"]:
        return ""

    return f"""
    <div class="permission-controls">

        {render_acl_status(folder)}

        {render_owner(folder)}

        {render_permissions(folder)}

        {render_errors(folder)}

    </div>
    """


# ============================================================
# RENDER FOLDER
# ============================================================

def render_folder(folder):

    name = html.escape(str(folder["name"]))

    path = html.escape(str(folder["path"]))

    size = html.escape(format_size(folder))

    files = html.escape(str(folder["file_count"]))

    status = html.escape(str(folder["status"]))

    status_class = status.lower()

    if status_class not in (
        "success",
        "failed",
        "partial",
        "unknown"
    ):
        status_class = "unknown"

    permission_controls = render_folder_permissions(folder)

    children_html = ""

    for child in sorted(
        folder["children"],
        key=lambda x: x["name"].casefold()
    ):

        children_html += render_folder(child)

    # Folder containing subfolders

    if folder["children"]:

        return f"""
        <details class="folder">

            <summary>

                <span class="folder-name">
                    📁 {name}
                </span>

                {permission_controls}

                <span class="folder-size">
                    {size}
                </span>

                <span class="folder-files">
                    {files} files
                </span>

                <span class="folder-status {status_class}">
                    {status}
                </span>

            </summary>

            <div class="folder-path">
                {path}
            </div>

            <div class="children">
                {children_html}
            </div>

        </details>
        """

    # Folder without subfolders

    return f"""
    <div class="folder leaf">

        <div class="leaf-row">

            <span class="folder-name">
                📁 {name}
            </span>

            {permission_controls}

            <span class="folder-size">
                {size}
            </span>

            <span class="folder-files">
                {files} files
            </span>

            <span class="folder-status {status_class}">
                {status}
            </span>

        </div>

        <div class="folder-path">
            {path}
        </div>

    </div>
    """


# ============================================================
# GENERATE HTML
# ============================================================

def generate_html(roots, output_file):

    print("Generating HTML...")

    tree_html = ""

    for folder in sorted(
        roots,
        key=lambda x: x["name"].casefold()
    ):

        tree_html += render_folder(folder)

    generated = datetime.now().strftime(
        "%d/%m/%Y %H:%M:%S"
    )

    document = f"""<!DOCTYPE html>

<html lang="en">

<head>

<meta charset="UTF-8">

<meta name="viewport" content="width=device-width, initial-scale=1.0">

<title>Robocopy Folder Size Report</title>

<style>

* {{
    box-sizing: border-box;
}}

body {{
    font-family: "Segoe UI", Arial, sans-serif;
    background: #f4f6f8;
    color: #252525;
    margin: 0;
    padding: 25px;
}}

h1 {{
    font-size: 25px;
    margin-bottom: 5px;
}}

.subtitle {{
    color: #777;
    font-size: 13px;
    margin-bottom: 20px;
}}

.toolbar {{
    margin-bottom: 15px;
}}

button {{
    padding: 8px 14px;
    border: 1px solid #ccc;
    border-radius: 5px;
    background: white;
    cursor: pointer;
    margin-right: 5px;
}}

button:hover {{
    background: #e8edf3;
}}

.report {{
    background: white;
    border-radius: 8px;
    padding: 15px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.06);
}}

.folder {{
    margin: 3px 0;
}}

.folder summary {{
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 9px 10px;
    cursor: pointer;
    border-radius: 5px;
    list-style: none;
}}

.folder summary::-webkit-details-marker {{
    display: none;
}}

.folder summary::before {{
    content: "▶";
    font-size: 10px;
    color: #777;
    width: 12px;
    flex-shrink: 0;
}}

.folder[open] > summary::before {{
    content: "▼";
}}

.folder summary:hover,
.leaf-row:hover {{
    background: #f0f4f8;
}}

.folder-name {{
    flex: 1;
    font-weight: 600;
    min-width: 120px;
}}

.folder-size {{
    width: 110px;
    text-align: right;
    font-family: Consolas, monospace;
    font-size: 13px;
    white-space: nowrap;
}}

.folder-files {{
    width: 100px;
    text-align: right;
    font-size: 13px;
    color: #666;
    white-space: nowrap;
}}

.folder-status {{
    width: 90px;
    text-align: center;
    padding: 3px 7px;
    border-radius: 4px;
    font-size: 12px;
    font-weight: 600;
}}

.success {{
    color: #16733b;
    background: #e3f5e9;
}}

.failed {{
    color: #b42318;
    background: #fde8e7;
}}

.partial {{
    color: #946200;
    background: #fff3cd;
}}

.unknown {{
    color: #666;
    background: #eee;
}}

/* Permission controls */

.permission-controls {{
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 5px;
    flex-shrink: 0;
}}

.acl-status {{
    display: inline-block;
    padding: 4px 7px;
    border-radius: 4px;
    background: #fff3cd;
    color: #946200;
    font-size: 11px;
    font-weight: 600;
    white-space: nowrap;
}}

.info-toggle {{
    font-size: 11px;
    padding: 4px 8px;
    margin: 0;
    border-radius: 4px;
    white-space: nowrap;
}}

.owner-button {{
    color: #245b91;
    background: #edf5ff;
    border-color: #c6d8ed;
}}

.permissions-button {{
    color: #245b91;
    background: #edf5ff;
    border-color: #c6d8ed;
}}

.error-button {{
    color: #b42318;
    background: #fde8e7;
    border-color: #efb6b2;
}}

.info-panel {{
    margin: 5px 10px 12px 38px;
    padding: 12px;
    background: #f8fafc;
    border: 1px solid #e1e5eb;
    border-radius: 6px;
    overflow-x: auto;
}}

.info-panel[hidden] {{
    display: none;
}}

.owner-content {{
    display: flex;
    gap: 10px;
    align-items: center;
    font-size: 13px;
    flex-wrap: wrap;
    word-break: break-all;
}}

.permissions-table {{
    width: 100%;
    border-collapse: collapse;
    font-size: 12px;
}}

.permissions-table th {{
    background: #edf1f5;
    text-align: left;
    padding: 8px;
    font-weight: 600;
}}

.permissions-table td {{
    padding: 8px;
    border-top: 1px solid #e5e7eb;
}}

.identity-cell {{
    font-family: Consolas, monospace;
    word-break: break-all;
}}

.permission-level {{
    display: inline-block;
    padding: 3px 7px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
}}

.full-control {{
    color: #16733b;
    background: #e3f5e9;
}}

.modify {{
    color: #245b91;
    background: #edf5ff;
}}

.read {{
    color: #946200;
    background: #fff3cd;
}}

.other-permission {{
    color: #555;
    background: #eee;
}}

.permission-detail {{
    display: inline-block;
    margin: 2px;
    padding: 3px 6px;
    border-radius: 4px;
    font-size: 10px;
}}

.explicit {{
    color: #946200;
    background: #fff3cd;
}}

.inherited {{
    color: #245b91;
    background: #edf5ff;
}}

.error-content {{
    color: #b42318;
    font-size: 13px;
    overflow-wrap: anywhere;
}}

.error-content p {{
    margin-bottom: 0;
}}

.children {{
    margin-left: 23px;
    padding-left: 12px;
    border-left: 1px solid #ddd;
}}

.folder-path {{
    font-size: 11px;
    color: #888;
    padding: 0 10px 7px 38px;
    word-break: break-all;
}}

.leaf {{
    padding: 8px 10px;
}}

.leaf-row {{
    display: flex;
    align-items: center;
    gap: 12px;
    border-radius: 5px;
    padding: 3px 0;
}}

.leaf .folder-name {{
    font-weight: 400;
}}

.leaf .folder-path {{
    padding-left: 25px;
}}

@media (max-width: 800px) {{

    body {{
        padding: 10px;
    }}

    .folder summary,
    .leaf-row {{
        gap: 6px;
        flex-wrap: wrap;
    }}

    .folder-name {{
        min-width: 100px;
    }}

    .folder-size,
    .folder-files,
    .folder-status {{
        width: auto;
    }}

    .permission-controls {{
        width: 100%;
    }}

    .info-panel {{
        margin-left: 10px;
    }}

}}

</style>

</head>

<body>

<h1>Robocopy Folder Size Report</h1>

<div class="subtitle">
    Generated: {generated}
</div>

<div class="toolbar">

    <button onclick="expandAll()">
        Expand all folders
    </button>

    <button onclick="collapseAll()">
        Collapse all folders
    </button>

</div>

<div class="report">

{tree_html}

</div>


<script>

// ============================================================
// FOLDER EXPANSION
// ============================================================

function expandAll() {{

    document.querySelectorAll("details.folder").forEach(folder => {{
        folder.open = true;
    }});

}}

function collapseAll() {{

    document.querySelectorAll("details.folder").forEach(folder => {{
        folder.open = false;
    }});

}}


// ============================================================
// OWNER / PERMISSIONS / ERROR PANELS
// ============================================================

function togglePanel(event, elementId) {{

    // Prevent the click from expanding or collapsing
    // the parent folder.

    event.preventDefault();
    event.stopPropagation();

    const panel = document.getElementById(elementId);

    if (panel) {{

        panel.hidden = !panel.hidden;

    }}

}}

</script>

</body>

</html>
"""

    output_path = Path(output_file)

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    output_path.write_text(
        document,
        encoding="utf-8"
    )

    print(f"HTML created: {output_path}")


# ============================================================
# MAIN
# ============================================================

def main():

    start_time = datetime.now()

    print("=" * 60)
    print("ROBOCOPY FOLDER SIZE HTML REPORT")
    print("=" * 60)

    print(f"Input CSV       : {INPUT_CSV}")
    print(f"Permission CSV  : {PERMISSION_CSV}")
    print(f"Output HTML     : {OUTPUT_HTML}")

    # Read permission information
    permissions = read_permissions(PERMISSION_CSV)

    # Read folder sizes and attach permission information
    roots = read_csv(
        INPUT_CSV,
        permissions
    )

    # Generate HTML
    generate_html(
        roots,
        OUTPUT_HTML
    )

    duration = datetime.now() - start_time

    print("=" * 60)
    print("Completed successfully.")
    print(f"Duration: {duration}")
    print("=" * 60)


if __name__ == "__main__":
    main()
