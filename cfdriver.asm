*******************************************************************
* FLEX 9.0 DISK DRIVER -- CompactFlash, True IDE 16-bit mode,     *
* low byte of each 16-bit strobe kept (D8-D15 not wired).         *
*                                                                  *
* One physical CF/ATA LBA block (always 512 bytes at the card's   *
* own protocol level) stores exactly one FLEX sector (256 bytes): *
* 256 word-strobes per sector, one usable byte captured per       *
* strobe. No SET FEATURES negotiation is needed -- 16-bit is the  *
* card's mandatory, un-negotiated default mode, which is the      *
* whole point: it sidesteps 8-bit-mode support being spotty       *
* across CF cards.                                                *
*                                                                  *
* HARDWARE-SPECIFIC -- fill these in before assembling:           *
*   CFBASE  base address of the CF task file registers as your    *
*           address decode presents them to the 6809              *
*   SPT     sectors per track; must match whatever the NEWDISK-   *
*           style formatter writes into the SIR                   *
*                                                                  *
* D8-D15 on the CF connector: tie to a fixed level (a pull-down    *
* resistor pack is simplest) rather than leaving floating. The    *
* card drives real data on those lines every access whether you   *
* sample them or not, and expects defined levels there on writes. *
*******************************************************************

CFBASE  EQU     $E000           ; <-- SET to your decoded base address
SPT     EQU     40              ; <-- sectors/track; must match formatter

* Task file register offsets from CFBASE. Only /CS0 is assumed
* wired (registers 0-7); the alternate-status/device-control (CS1)
* block is not used here -- see INIT notes if you want a hardware
* SRST reset later.
CFDATA  EQU     CFBASE+0        ; Data (r/w, 16-bit strobe)
CFERR   EQU     CFBASE+1        ; Error (r) / Features (w) -- unused
CFSECCT EQU     CFBASE+2        ; Sector Count
CFLBA0  EQU     CFBASE+3        ; LBA bits 0-7
CFLBA1  EQU     CFBASE+4        ; LBA bits 8-15
CFLBA2  EQU     CFBASE+5        ; LBA bits 16-23
CFDEVHD EQU     CFBASE+6        ; Device/Head: LBA bits 24-27, mode, drive
CFSTAT  EQU     CFBASE+7        ; Status (r)
CFCMD   EQU     CFBASE+7        ; Command (w)

STBSY   EQU     $80             ; Status: Busy
STDRQ   EQU     $08             ; Status: Data Request
STERR   EQU     $01             ; Status: Error

CMDRD   EQU     $20             ; Read Sectors
CMDWR   EQU     $30             ; Write Sectors

DEVHDV  EQU     $E0             ; LBA mode, drive 0 (master), LBA24-27=0

*******************************************************************
* Driver jump table -- must occupy $DE00-$DE1D exactly. Layout    *
* and offsets confirmed against a working FLEX/6809 disk driver.  *
*******************************************************************
        ORG     $DE00
DREAD   JMP     RDSEC           ; $DE00
DWRITE  JMP     WRSEC           ; $DE03
DVERFY  JMP     RDSEC           ; $DE06  -- verify = read (see note below)
RESTOR  JMP     NOOPOK          ; $DE09  -- no physical head to restore
DRIVE   JMP     SELDRV          ; $DE0C
DCHECK  JMP     CHKRDY          ; $DE0F
DQUICK  JMP     CHKRDY          ; $DE12
DINIT   JMP     CFINIT          ; $DE15
DWARM   JMP     NOOPOK          ; $DE18
DSEEK   JMP     NOOPOK          ; $DE1B  -- LBA is computed fresh each call

*******************************************************************
* Scratch storage (driver-local, not shared with FMS)
*******************************************************************
SVTRK   RMB     1
SVSEC   RMB     1
LBATMP  RMB     2

*******************************************************************
* CFINIT -- called once at cold start. True IDE 16-bit needs no
* feature negotiation, so this just confirms the card answers.
*******************************************************************
CFINIT  LBSR     WAITRDY
        LBCS     ERREXIT
        LBRA     OKEXIT

*******************************************************************
* NOOPOK, SELDRV, CHKRDY -- trivial on solid-state media: no seek,
* no warm-start re-init, and only one CF card (drive 0) supported.
*******************************************************************
NOOPOK  LBRA     OKEXIT

SELDRV  LBRA     OKEXIT          ; ignores requested drive # (single CF)

CHKRDY  LBSR     WAITRDY
        LBCS     ERREXIT
        LBRA     OKEXIT

*******************************************************************
* RDSEC -- Read one FLEX sector (256 bytes)
* Entry:  A = track, B = sector, X = buffer address
* Exit:   (C)=0 and A=0            success
*         (C)=1 and A<>0 (A=$FE)   failure
*
* DVERFY is aliased straight to RDSEC: FLEX's VERIFY call supplies
* a real buffer the same as READ does, so re-reading into it and
* reporting the same success/fail status is a correct, minimal
* VERIFY without needing a second scratch buffer -- driver space
* here is only 512 bytes total ($DE00-$DFFF), worth keeping tight.
*******************************************************************
RDSEC   STA     SVTRK
        STB     SVSEC
        LBSR     CALCLBA
        LDA     #CMDRD
        STA     CFCMD
        LBSR     WAITDRQ
        LBCS     ERREXIT
        LDB     #0
RDLOOP  LDA     CFDATA          ; 16-bit strobe; only D0-D7 wired/kept
        STA     0,X+
        DECB
        BNE     RDLOOP
        LBSR     WAITBSYCLR
        LBCS     ERREXIT
        LBRA     OKEXIT

*******************************************************************
* WRSEC -- Write one FLEX sector (256 bytes)
* Entry/exit convention identical to RDSEC.
*******************************************************************
WRSEC   STA     SVTRK
        STB     SVSEC
        LBSR     CALCLBA
        LDA     #CMDWR
        STA     CFCMD
        LBSR     WAITDRQ
        LBCS     ERREXIT
        LDB     #0
WRLOOP  LDA     0,X+
        STA     CFDATA          ; 16-bit strobe; D8-D15 must be tied,
        DECB                    ; not floating -- see header notes
        BNE     WRLOOP
        LBSR     WAITBSYCLR
        LBCS     ERREXIT
        LBRA     OKEXIT

*******************************************************************
* CALCLBA -- LBA = SVTRK x SPT + (SVSEC - 1); loads Sector Count,
* LBA0-2 and Device/Head. FLEX sectors are 1-based, tracks 0-based.
* Preserves A, B and X.
*******************************************************************
CALCLBA PSHS    A,B,X
        LDA     SVTRK
        LDB     #SPT
        MUL                     ; D = SVTRK x SPT
        STD     LBATMP
        LDD     #0
        LDB     SVSEC
        SUBD    #1              ; D = SVSEC - 1 (zero-extended)
        ADDD    LBATMP
        STD     LBATMP

        LDA     #1
        STA     CFSECCT
        LDA     LBATMP+1        ; low byte of the 16-bit LBA
        STA     CFLBA0
        LDA     LBATMP          ; high byte
        STA     CFLBA1
        CLRA
        STA     CFLBA2
        LDA     #DEVHDV
        STA     CFDEVHD
        PULS    A,B,X
        RTS

*******************************************************************
* Bounded busy-wait helpers. All time out rather than hang forever
* if the card is missing or wedged. $FFFF iterations is generous;
* tighten it once you've measured real timing on your hardware.
*******************************************************************
WAITRDY LDX     #$FFFF
WRDY1   LDA     CFSTAT
        BITA    #STBSY
        BEQ     OKEXIT
        LEAX    -1,X
        BNE     WRDY1
        LBRA     ERREXIT

WAITDRQ LDX     #$FFFF
WDRQ1   LDA     CFSTAT
        BITA    #STBSY
        BNE     WDRQ2
        BITA    #STERR
        BNE     ERREXIT
        BITA    #STDRQ
        BNE     OKEXIT
WDRQ2   LEAX    -1,X
        BNE     WDRQ1
        LBRA     ERREXIT

WAITBSYCLR LDX  #$FFFF
WBC1    LDA     CFSTAT
        BITA    #STBSY
        BEQ     WBC2
        LEAX    -1,X
        BNE     WBC1
        LBRA     ERREXIT
WBC2    BITA    #STERR
        BNE     ERREXIT
        LBRA     OKEXIT

*******************************************************************
* Shared exit points -- sets BOTH carry and A=0/A<>0 on the way
* out, since the Adaptation Guide references carry- and zero-flag
* conventions in different places and the full per-routine detail
* wasn't confirmable from a source I could actually fetch. Belt
* and suspenders until this is verified against your own copy or
* by testing against real FLEX.
*******************************************************************
OKEXIT  CLRA
        ANDCC   #$FE
        RTS

ERREXIT LDA     #$FE
        ORCC    #1
        RTS

        END
