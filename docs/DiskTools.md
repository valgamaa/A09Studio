# A09 Studio — Disk and File Management

A09 Studio has three tools for working with FLEX disk images (`.dsk`) and
getting them onto the 6809 board's CF card. All three open from the toolbar:

| Toolbar button | What it is for |
|---|---|
| **Disk Builder…** | Make a new FLEX disk image from host files, or add files to an existing image |
| **DSK Browser…** | Look through a folder full of disk images, find files, and copy chosen ones out |
| **Disk Image…** | Send a finished `.dsk` to the CF card on the board over the serial link |

A typical workflow: browse old disks with the **DSK Browser**, add the files
you want to a new image, build it, and send it to the CF card with **Disk
Image**. Or use the **Disk Builder** directly when your files are already on
the Mac.

---

## 1. Background: what a FLEX disk image is

A `.dsk` file is a sector-for-sector copy of a FLEX disk. Sectors are 256
bytes. The app reads the disk's own System Information Record (SIR) to find
out how many tracks and sectors per track it has, so you rarely need to
enter geometry by hand.

Things to know about FLEX files:

- Names are up to **8 characters**, with an extension of up to **3**
  (`XBASIC.CMD`). The app upper-cases names. A name must start with a
  letter and may contain only letters, digits, `-` and `_`. A name that
  breaks these rules is flagged in red and the image can't be built until
  you fix it.
- Files are one of three kinds when you add them from the Mac:
  - **Binary** — machine code or data, copied as-is. Use for `.CMD`, `.BIN`
    and similar.
  - **Text** — Mac text is converted to FLEX text (line ends become the
    FLEX end-of-line, runs of spaces are compressed, and the end of the file
    is padded).
  - **S-record / hex** — Motorola S-record (`.S19`, `.S09`…) or Intel hex is
    converted to a FLEX binary file with its load addresses and start
    address.
- **6800 and 6809 FLEX are different.** A 6800 program will not run under
  6809 FLEX. The DSK Browser flags files that look like 6800 programs with a
  warning symbol.

---

## 2. Disk Builder

Open it with **Disk Builder…**. The window title is *Disk Builder → FLEX
.dsk*.

### Choose the image

The first control picks the mode:

- **New image** — creates an empty FLEX disk and puts your files on it.
  - **Geometry** — pick a preset (5.25" and 3.5" floppy sizes, or **CF
    large (256 × 255)**) or **Custom…** and enter tracks (2–256) and
    sectors per track (5–255). The line underneath shows the size, free
    sectors and number of directory slots.
  - **Volume label** and **Volume number** — written into the disk.
  - A small disk is much quicker to send over the serial link than the
    large CF size, so choose the smallest geometry your files fit in.
- **Open existing .dsk** — click **Choose…** to pick an image. The app
  checks it and shows its geometry, label, file count and free sectors.
  Files are added to this image.

### Add files

- Click **Add Files…**, or **drag files or a whole folder** onto the window.
- **Add Assembled Output** adds the result of your latest successful
  assembly from the Assembler tab.
- **Clear** empties the list.

Each file shows its **Name**, **Ext**, **Type**, **Sectors** and
**Attr**. You can edit the name and extension, change the type
(Binary / Text / S-record) and set the protection attributes:

- **W** write protect, **D** delete protect, **R** read protect,
  **C** catalog protect.

The app picks the type from the file contents and extension. It treats
hex or S-record text as an S-record even if it is called `.CMD`, so you
don't end up with text stored as if it were machine code. For an S-record
file that has no start address of its own, a **Start $** box appears so you
can enter one (in hex). Without it, the program loads but nothing runs
automatically at the end of the load.

A **Notes** column explains anything the converter changed or couldn't
do, for example *no start address in the file* or bytes dropped above
`$7F` in a text file.

A line under the file list shows how many sectors and directory slots the
files need, and how many remain free afterwards. The **Build** button is
disabled if the files don't fit, or if two files have the same name.

### Build the image

- **Build .dsk…** — asks where to save, builds the image, and **checks it**
  afterwards (directory, free chain, and every file's chain). Problems are
  reported in the log.
- **Send to CF…** — available after a build. Opens the Disk Image window
  with the new image selected (see section 4).
- **New Image from Folder…** — shortcut: choose a folder and the app
  builds a disk from every usable file in it, picking the smallest preset
  that fits. The image is saved next to the folder as `FOLDERNAME.dsk`.
  Files it can't use are listed as skipped in the log.

The **Log** at the bottom records what was added, skipped or changed.

---

## 3. DSK Browser

Open it with **DSK Browser…**. It has three panels, with **Add** buttons
between the second and third.

```
┌─ Disk images ─┐   ┌─ Files on selected disk ─┐ [Add]  ┌─ Files to copy ─┐
│ search box    │   │ File Type Sect Date …CRC │ [Add   │ name   from …   │
│ DSK list      │   │                          │  all]  │ target options  │
└───────────────┘   └──────────────────────────┘        └─────────────────┘
```

### Left panel — disk images

1. Click **Choose Folder…** and pick a folder. All `.dsk`, `.img` and
   `.flx` files in it, including sub-folders, are indexed in the
   background. The progress is shown at the top of the panel.
2. Type in the **search box** to narrow the list. It matches disk file
   names and folder names, **and the names of files inside the disks**.
   Disks that match through a file inside them show the matching names
   under the disk name.

   **Wildcards:** `*` matches any run of characters and `?` any single
   character, e.g. `*.CMD` (all `.CMD` files), `XB?.*`, `CAT*`. A pattern
   with a wildcard must match the whole file name (`NAME.EXT`), so `*.CMD`
   finds only names ending in `.CMD`. Without a wildcard the text is matched
   anywhere in the name. Case is ignored.
3. Tick **Also filter the file list** to apply the same search to the
   middle panel as well, so selecting a disk shows only the files whose
   names match. A line under the list says how many files are shown. Untick
   it to see everything on a disk again.
4. Disks that can't be read as FLEX images (empty, too short, or with a
   damaged System Information Record) are hidden by default. The count is
   shown as **Hide N unreadable**; untick it to see them. Selecting one
   shows the reason in the middle panel.

### Middle panel — files on the selected disk

Select a disk to list its files. Columns:

| Column | Meaning |
|---|---|
| File | Name and extension |
| Type | Binary, Text, Data or Random |
| Sect | Number of sectors used |
| Date | The file's directory date |
| Attr | W / D / R / C protection flags |
| CRC32 | A checksum of the file's contents |

- **Selecting files:** click one, or use Shift-click and Command-click for
  several. A box below the list shows details and a preview of the selected
  file: text for text files, a hex dump for others, and warnings.
- **Warnings:** a file marked with a warning symbol has a problem — for
  example the directory sector count differs from the actual chain, or it
  looks like a 6800 program.
- **CRC32:** two copies of a file with the same CRC are byte-for-byte
  identical (trailing zero padding is ignored). This is the quick way to
  compare copies of the same program from different disks.
- **Random files** (FLEX random-access files) are listed but cannot be
  copied.

If a disk has structural problems the panel shows a warning, and the files
from it may be damaged.

### Add button

Between the middle and right panels:

- **Add** — adds the selected files to the *Files to copy* list. The
  right-click menu has the same command (**Add to list**).
- **Add all** — adds every file currently shown. With the search filter on,
  only the matching files are added.

### Right panel — files to copy

The list shows each file's name, sectors, source disk and CRC. You can edit
a name or extension before building and remove entries individually or with
**Clear**. A red message appears if two files would have the same name.

At the bottom is where the files go:

- **Target** — **New image** (choose a size, or leave it on **Automatic
  (smallest that fits)**, plus a label and volume number) or **Add to
  existing .dsk** (**Choose…** an image).
- **Build .dsk…** — writes the new image (or adds to the existing one).
- **Send to CF…** — available after a build; opens the Disk Image window
  with the image selected.
- **Save to Mac…** — instead of making a disk, saves each file as a
  separate file in a folder you choose. This is for extracting files to
  look at or compare. File names keep the FLEX name and extension.
  - **Text → Mac text** (on by default) converts FLEX text files to Mac text
    as they are saved. Turn it **off** for binary files such as `.CMD`
    programs, so they are saved byte-for-byte.

### Finding and comparing copies of a program

1. Choose the folder of disks, type the name in the search box, and tick
   **Also filter the file list**.
2. Click down the list of disks; each shows the matching file.
3. Select the file on each disk and click **Add**. The *Files to copy* list
   keeps the source disk and CRC32 of each one.
4. Click **Save to Mac…** into an empty folder, with **Text → Mac text**
   off for binaries.

Files with the same CRC are the same version, so you only need one of each.

---

## 4. Disk Image → CF Card

Open it with **Disk Image…**. This sends a `.dsk` file to the CF card on the
board over the serial link, sector by sector. FLEX itself is not involved.

### Before you start

1. Connect to the board on the **Terminal** tab.
2. Download `Flex_BIOS.asm` to the board, as for any FLEX session.
3. Start the receiver program on the board: download
   `Flex_BIOS_DiskLoader.asm`, then run it with the monitor's `U` command.
   The receiver initialises the CF card and replies that it is ready.

If the app isn't connected, or the receiver isn't running, the window shows
a warning.

### Send

1. Click **Choose…** and pick the `.dsk` image (a freshly built image may
   already be selected, if you came from **Send to CF…**).
2. Check the geometry. The app reads it from the image and shows *Detected
   from the image's own SIR…* If it can't, enter **Sectors per track**
   yourself. A warning appears when the sector count doesn't divide evenly
   into that number of sectors per track.
3. Choose the **Target drive**.
4. Click **Start Transfer**. Each sector is sent with a checksum and
   acknowledged by the board; a failed sector is retried. **Cancel** stops
   the transfer.

When the transfer finishes, the receiver returns to the monitor and you can
boot FLEX from the card.

> **Note:** sending an image overwrites the target drive on the CF card.
> The clock chip is not touched by the transfer, but if you power-cycle the
> board while doing this and find a bad date, run `K` to set the clock again.

---

## 5. Troubleshooting

| Symptom | What to check |
|---|---|
| A disk shows "Not a FLEX image" with a reason | The file is empty or damaged. Untick **Hide unreadable** to list them; nothing in them can be copied. |
| "Image has structural problems" warning | The directory or free chain is inconsistent. Files may be damaged — compare the CRC with other copies. |
| A file shows a 6800 warning | It was built for 6800 FLEX and will not run on 6809 FLEX. Find the 6809 version. |
| **Build .dsk…** is greyed out | The files don't fit in the chosen size, or two entries share a name. |
| A copied `.CMD` doesn't run | Check it was saved with **Text → Mac text** off, if you saved to the Mac. |
| Transfer reports NAK or no response | Confirm the receiver is running (`U` command) and the serial port is connected. |
| FLEX reports an invalid date after a transfer | Run `K` on the board to set the clock. |
