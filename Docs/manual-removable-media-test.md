# Manual removable-media validation

Use a disposable test card. CardVault V1 never writes to it, but the procedure should not put the
only copy of valuable work at risk.

1. Prepare an SD card containing RAW, JPEG/HEIF, video, sidecar, zero-byte, Unicode-named, and nested files.
2. Insert it, confirm automatic detection, then repeat with manual source selection.
3. Run Preserve Card to an APFS destination. Confirm the staging folder is hidden/incomplete,
   copying and verification are distinct phases, and the final folder appears only after verification.
4. Compare `shasum -a 256` for representative source and destination copies. Inspect the JSON manifest.
5. Repeat with HFS+ and exFAT destinations. Test names containing case-only differences and characters
   prohibited by the destination; CardVault must block rather than overwrite.
6. Add a second physical drive and confirm both results are independent. Repeat with two folders on
   one drive, and with two partitions of one drive, and confirm the independence warning in each case.
   Unmount and remount the card; confirm it is recognized as the same volume even at `/Volumes/NAME 1`,
   and that a reformatted card reusing its old label is treated as a different volume.
7. During separate transfers disconnect the source, primary, and backup; exhaust destination space;
   revoke folder access; sleep/wake the Mac; quit/force-quit between files; and relaunch. Confirm an
   incomplete manifest remains, verified files are not overwritten, and retry begins at a file boundary.
8. After a verified transfer, use Show in Finder. Eject only when the UI says Safe to eject. Confirm
   the UI never says that the card is safe to erase.
9. Hold the card busy (open a Finder window on it or a Preview of one of its files) and eject. Confirm
   the failure names the volume and offers a recovery action, then release the card and eject again.
10. Run the opt-in Disk Arbitration tests against real media:
    `CARDVAULT_DEVICE_VOLUME=/Volumes/CARD swift test --filter DiskArbitrationManualTests`. Add
    `CARDVAULT_DEVICE_EJECT=1` to include the test that really ejects the device.
