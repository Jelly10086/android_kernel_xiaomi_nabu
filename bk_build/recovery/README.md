# Embedded PBRP recovery

Source: `PBRP-nabu-4.0-20241222-2341-UNOFFICIAL.zip`

- Source ZIP SHA256: `77a06f1bfdcd0d4e47c89d83f95a1b650217c067085808e361510461d9608203`
- Raw `ramdisk-recovery.cpio` SHA256: `15ae763c1f5b93ae48bcd007ff1f66871873aaee5b3a32852acbbf75b897fc54`
- Deterministic gzip payload SHA256: `248feef8879116c86df1729ecf9595b4be50834dd5bd66fe5732953cafaa4602`

The AnyKernel installer replaces only the active boot ramdisk. It does not run
PBRP's original two-slot installer and does not modify the inactive slot.
