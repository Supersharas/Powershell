
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
            "Identity",
            "Permissions"
        }

        if not required_columns.issubset(reader.fieldnames or []):
            raise ValueError(
                "Permission CSV is missing required columns: "
                "Path, Identity, Permissions"
            )

        for row in reader:

            # Only process folder permissions
            record_type = row.get("Type", "").strip()

            if record_type and record_type.casefold() != "folderpermission":
                continue

            folder_path = row.get("Path", "").strip()

            identity = row.get("Identity", "").strip()

            permission_level = row.get("Permissions", "").strip()

            if not folder_path or not identity:
                continue

            path_key = normalise_path(folder_path)

            if path_key not in permissions:
                permissions[path_key] = []

            permissions[path_key].append({

                "identity": identity,

                "permissions": permission_level or "Unknown",

                "access_type": row.get(
                    "AccessType", "Unknown"
                ).strip(),

                "inherited": row.get(
                    "Inherited", "Unknown"
                ).strip()

            })

    total_entries = sum(
        len(entries) for entries in permissions.values()
    )

    print(f"Permission paths discovered: {len(permissions)}")
    print(f"Permission entries discovered: {total_entries}")

    return permissions


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

                "permissions": permissions.get(path_key, []),

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
# RENDER PERMISSIONS
# ============================================================

def render_permissions(folder):

    entries = folder["permissions"]

    if not entries:
        return ""

    # Generate a unique HTML element ID
    element_id = "perm-" + hashlib.md5(
        folder["path"].encode("utf-8")
    ).hexdigest()

    permission_rows = ""

    for entry in sorted(
        entries,
        key=lambda x: x["identity"].casefold()
    ):

        identity = html.escape(entry["identity"])

        permission = html.escape(entry["permissions"])

        access_type = html.escape(entry["access_type"])

        inherited = html.escape(entry["inherited"])

        access_class = (
            "allow"
            if access_type.casefold() == "allow"
            else "deny"
            if access_type.casefold() == "deny"
            else "unknown"
        )

        inherited_class = (
            "inherited"
            if inherited.casefold() == "true"
            else "explicit"
            if inherited.casefold() == "false"
            else "unknown"
        )

        permission_rows += f"""
        <tr>

            <td class="identity-cell">
                {identity}
            </td>

            <td>
                {permission}
            </td>

            <td>
                <span class="access-badge {access_class}">
                    {access_type}
                </span>
            </td>

            <td>
                <span class="inheritance-badge {inherited_class}">
                    {inherited}
                </span>
            </td>

        </tr>
        """

    return f"""
    <button
        type="button"
        class="permission-toggle"
        onclick="togglePermissions(event, '{element_id}')"
    >
        🔐 Permissions ({len(entries)})
    </button>

    <div
        class="permissions-panel"
        id="{element_id}"
        hidden
    >

        <table class="permissions-table">

            <thead>
                <tr>
                    <th>Identity</th>
                    <th>Permissions</th>
                    <th>Access</th>
                    <th>Inherited</th>
                </tr>
            </thead>

            <tbody>
                {permission_rows}
            </tbody>

        </table>

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

    permissions_html = render_permissions(folder)

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

                {permissions_html}

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

            {permissions_html}

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

.permission-toggle {{
    font-size: 11px;
    padding: 4px 8px;
    margin: 0;
    border: 1px solid #c6d8ed;
    background: #edf5ff;
    color: #245b91;
    border-radius: 4px;
    white-space: nowrap;
    flex-shrink: 0;
}}

.permission-toggle:hover {{
    background: #dcecff;
}}

.permissions-panel {{
    margin: 5px 10px 12px 38px;
    padding: 10px;
    background: #f8fafc;
    border: 1px solid #e1e5eb;
    border-radius: 6px;
    overflow-x: auto;
}}

.permissions-panel[hidden] {{
    display: none;
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
    padding: 7px 8px;
    border-top: 1px solid #e5e7eb;
}}

.identity-cell {{
    font-family: Consolas, monospace;
    word-break: break-all;
}}

.access-badge,
.inheritance-badge {{
    display: inline-block;
    padding: 3px 7px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
}}

.allow {{
    color: #16733b;
    background: #e3f5e9;
}}

.deny {{
    color: #b42318;
    background: #fde8e7;
}}

.inherited {{
    color: #245b91;
    background: #edf5ff;
}}

.explicit {{
    color: #946200;
    background: #fff3cd;
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

    .permissions-panel {{
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
// PERMISSION EXPANSION
// ============================================================

function togglePermissions(event, elementId) {{

    // Prevent clicking the permissions button from
    // expanding or collapsing the parent folder.

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

    # Read permissions first
    permissions = read_permissions(PERMISSION_CSV)

    # Read folder sizes and attach permissions
    roots = read_csv(
        INPUT_CSV,
        permissions
    )

    # Generate report
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
