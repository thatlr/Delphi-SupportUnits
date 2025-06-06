unit PrintersEx;

{
  This is a thread-safe alternative to Delphi's "Printers" unit. As such, it offers no global Printer variable,
  but instead allows to create any number of TPrinterEx objects in parallel, for the same or for different printers,
  in the same or in different threads.

  Enhancements over the VCL unit "Printers":

  - Completely thread-safe.
  - Correct handling of dialog cancellation during print-to-file / print-to-PDF.
  - No use of obsolete Win95-like constructs like GlobalAlloc or GetPrinter/SetPrinter with Device+Port+Driver.
  - Offers more printers settings to query and select, like paper formats and paper sources (aka "bins").
  - Retrieves the Windows print job ID.
  - Allows to select custom paper sizes (support depends on the printer driver, as for all other settings).
  - Allows changing of page properties from page to page inside a print job (for example, the orientation).
  - Allows print-to-file by the application.
  - Allows to query page size, printable area and non-printable page margins.
  - Calling Abort is always possible (even when no job is active), so exception handling by the app is straight-forward.
  - Error checking at all GDI calls.

  Differences in behavior:

  - Accessing printer settings not supported by the printer will cause an exception. Even reading such a setting has no
	meaning if the printer driver does not support this concept (for example, receipt printers have no concept of
	landscape/portrait orientation or paper formats).

  - When OptimizeResetDC is not set, all device context properties that are not represented by VCL objects are reset for
	each page: This means that Pen, Brush, Font, CopyMode and TextFlags are retained, but PenPos and everything one can
	set directly at the GDI Device Context (like Mapping Mode, global transformation) start fresh.
	When OptimizeResetDC is set, this happens only when format settings (like PageOrientation) are changed within a
	job.
	Setting OptimizeResetDC could have a positive effect with printer drivers for printers with special features
	(like dedicated memory for temporarily storing fonts or images).

  - A Windows print job can be cancelled at any time, for example if some other app calls Windows.SetJob(, JOB_CONTROL_DELETE)
	or Windows.SetPrinter(, PRINTER_CONTROL_PURGE). Due to this, the methods BeginDoc((), NewPage() and EndDoc() may
	return false. The application must check and handle this, as continuing to print is pointless, and the Windows
	documentation does not describe if the print API calls are even supposed to fail at job cancellation (but sometimes,
	they do).


  Threading:

  - You need to take this TBitmap issue into account:
	https://stackoverflow.com/questions/53696554/gdi-printer-device-context-in-a-worker-thread-randomly-fails

  - Up to and including Delphi 10.1, TWICImage is not thread-safe (FImagingFactory not correctly managed). This is fixed
	in Delphi 10.3 (TWICImage.ImagingFactory is still broken, as it does not attempt to create the interface
	when it is currently not allocated).


  Font sizes:

  TFont have a Size and a Height property, of which Size is device-independent, and Height is expressed in the logical
  unit of measure that the output device is using for its Y axis (normally, this logical unit is "Pixel", as the
  default GDI mapping mode is MM_TEXT).

  You need to take into account the following:

  - TFont.Create() sets the PixelPerInch property to the DPI value of the Windows desktop (Graphics.pas: InitScreenLogPixels),
	as detected at startup of the program.

  - If you assign a font object to another font object and the PixelsPerInch valus of both are different, then
	TFont.Assign() will recalculate the Height at the target object to match the target's PixelPerInch value. This
	recalculation may cause some rounding error (Height in source units => Size => Height in destination units).

  - TFont.PixelPerInch is misnamed. It should be called UnitsPerInch, as this is how it works when the logical units
	of the respective TCanvas in not Pixel (MM_TEXT) but something else.

  Therefore, if you want to specify the font size as accurately as possible, you should not set TFont.Size, but rather
  TFont.PixelsPerInch *and* TFont.Height as follows:
	f.PixelsPerInch := PrinterObj.UnitsPerInch;
	f.Height := <Height in the logical Y units accoding to the current GDI mapping mode>;
  The Font object used by TPrinterEx.Canvas always has its PixelsPerInch property set to the correct value, so the
  previous advice applies only to font objects created independently.


  Using pixels as coordinates:

  Dont do this. Some printers have different DPI for X and Y axis, like 4800 x 1200 and different printers will have
  different physical resolutions: Let Windows do the heavy lifting of converting device-independent coordinates to
  whatever the specific printer needs.
  Although TCanvas does not explicitly support it, the application can use custom units of measurement for all TCanvas
  operations:
  - Call TPrinterEx.SetMapMode() as the first action on each page to specify the "logical unit" that will subsequently
	be used for all dimensions and coordinates.
  - Specify TPen.Width, TFont.Height and all extents and coordinates in the selected logical unit.
  - TCanvas.TextWidth and the like will correctly use the logical unit set by SetMapMode().
  - For extra precision, use TFont.Height instead of TFont.Size, as this will prevent some rounding error due to .Size
	using a unit of measure of 1/72 inch.
  - If you create TFont objects, set TFont.PixelPerInch to TPrinterEx.UnitsPerInch together with TFont.Height: This will
	cause .Height to be used "as is", without going through a double-conversion via the .Size value from 96 dpi to the
	printer's logical unit.


  Unsafe printer drivers

  There are printer drivers which are not thread-safe, somehow: This is surprising because 64-bit printer drivers are
  not loaded into a 32-bit process at all, and Windows uses "splwow64.exe" as a bridge from the 32bit app to the 64bit
  spooler and the driver. Also, the "driver isolation" feature (when activated) should shield even the spooler from
  misbehaving drivers.
  However, when used by multiple threads in parallel, the Microsoft PostScript printer driver in Windows 10 (PSCRIPT5.DLL,
  version 0.3.19041.3693) causes access violations during the GDI call SelectObject() for fonts. The Windows Application
  Verifier detect the use of null handles at a call to KERNELBASE.MapViewOfFile by gdi32full.dll.
  (https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/application-verifier)
  On the other hand, the driver "HP Universal Printing PCL 6 (v6.4.1)" just works.
  To exclude the TCanvas implementation as a source of the error, a test with memory device contexts shows no failure.
  There seems to be some bug in the Windows GDI printing support which is really unsatisfactory.


  Bugs in printer drivers

  There are printer drivers (example: ZDesigner, for Zebra printers) which seem to misinterpret calls to ResetDC() as
  the start of another job. If ResetDC() is called between pages, the ZDesigner driver injects the command sequence for
  the start of a print job before each page instead of only at the real start of the print job. To prevent this, the
  property OptimizeResetDC of TPrinterEx should be set.

  There are printer drivers that do not correctly implement world transformation, specifically the rotation by 90° or 270°
  in BitBlt(), StretchBlt() and similar GDI calls. The observed effect is a shift of the bitmap by one pixel in both X and
  Y directions: The bitmap is shifted by one pixel, one row and one column of the bitmap disappears and a black row/column
  of one pixel is drawn on the other side of the bitmap.
  One way to get around this is to implement the rotation (and possibly the stretch and the transformation from world to
  device coordinates) yourself; thereby not using TCanvas.Draw() or TBitmap.Draw().

  The Microsoft PostScript printer driver in Windows 10 (PSCRIPT5.DLL, version 0.3.19041.3693) does not create multiple
  copies of a page, if the print job contains only one single page.

  'Microsoft Print to PDF' does not produce monochrome output when UseColor is set to false.


  SaveDC/RestoreDC/GDI objects

  If you use SaveDC/RestoreDC, or if you manually select objects into the DC by Windows.SelectObject(), you must make
  sure to keep the state of the device context in sync with the TCanvas object.

  For example, this sequence of calls

		.....
		save := Windows.SaveDC(DC);
		.....
		p.Canvas.Refresh;
		Win32Check(Windows.RestoreDC(DC, save));
		.....
		p.NewPage;

  will cause this error when used in a multi-thread application:

  Access violation at address 7629EAAA in module 'gdi32full.dll'. Read of address 0000008C
   at gdi32full.dll: METALINK::pmetalinkNext + 0x1A
   at gdi32full.dll: vFreeMHE + 0x3719F
   at gdi32full.dll: vFreeMDC + 0xAD
   at gdi32full.dll: UnassociateEnhMetaFile + 0x142
   at gdi32full.dll: MFP_InternalEndPage + 0xD8
   at gdi32full.dll: InternalEndPage + 0x74
   at gdi32full.dll: EndPageImpl + 0x10
   at GDI32.dll: EndPage + 0x3E
   at Test.exe: TPrinterEx.EndDoc in PrintersEx.pas (Line 578)

  Canvas.Refresh will set the TCanvas object to a state of "no objects are selected into the DC". RestoreDC() will then
  select the objects from SaveDC() back into the DC. Now, when the properties of p.Canvas.Font (or .Pen or .Brush) are
  changed, TCanvas.FontChanged() is called but will *not* deselect the font handle from the DC, and then the font handle
  is destroyed while being still selected into the DC.
  As these kinds of Delphi objects are pooled und shared across TCanvas instances, this error may affect a multi-threaded
  applications with a much higher probability.
  (About the example: As there is no reliable way to resync TCanvas with the state of the DC, it is best to avoid SaveDC
   + RestoreDC in the first place.)



  See also:

  "What is the correct way of using SaveDC and RestoreDC?"
	https://devblogs.microsoft.com/oldnewthing/20170920-00/?p=97055

  "Thread affinity of user interface objects, part 2: Device contexts"
	https://devblogs.microsoft.com/oldnewthing/20051011-10/?p=33823

  "Thread affinity of user interface objects, part 4: GDI objects and other notes on affinity"
	https://devblogs.microsoft.com/oldnewthing/20051013-11/?p=33783

  "What are the dire consequences of not selecting objects out of my DC?"
	"https://devblogs.microsoft.com/oldnewthing/20130306-00/?p=5043
}

{$include LibOptions.inc}

interface

uses
  Types,
  Windows,
  WinSpool,
  SysUtils,
  Graphics;

const
{$if declared(JOB_CONTROL_RETAIN)}
	JOB_CONTROL_RETAIN         = WinSpool.JOB_CONTROL_RETAIN;
	JOB_CONTROL_RELEASE        = WinSpool.JOB_CONTROL_RELEASE;
{$else}
	JOB_CONTROL_RETAIN         = 8;
	JOB_CONTROL_RELEASE        = 9;
{$ifend}

type
  EPrinter = class(Exception);

  // Defines operations for a print job.
  // https://learn.microsoft.com/en-us/windows/win32/printdocs/setjob
  TPrintJobCmd = (
	pjcPause   = WinSpool.JOB_CONTROL_PAUSE,	// Pause the print job.
	pjcRestart = WinSpool.JOB_CONTROL_RESTART,	// Restart the print job. A job can only be restarted if it was printing.
	pjcResume  = WinSpool.JOB_CONTROL_RESUME,	// Resume a paused print job.
	pjcDelete  = WinSpool.JOB_CONTROL_DELETE,	// Delete the print job.
	pjcRetain  = JOB_CONTROL_RETAIN,			// Windows Vista and later: Keep the job in the queue after it prints.
	pjcRelease = JOB_CONTROL_RELEASE			// Windows Vista and later: Release the print job.
  );

  // Current state of a print job.
  // https://learn.microsoft.com/en-us/windows/win32/printdocs/job-info-1
  TPrintJobStatusFlag = (
	pjsPaused,									// Job is paused.
	pjsError,									// An error is associated with the job.
	pjsDeleting,								// Job is being deleted.
	pjsSpooling,								// Job is spooling.
	pjsPrinting,								// Job is printing.
	pjsOffline,									// Printer is offline.
	pjsPaperout,								// Printer is out of paper.
	pjsPrinted,									// Job has printed.
	pjsDeleted,									// Job has been deleted.
	pjsBlocked,									// The driver cannot print the job.
	pjsIntervention,							// Printer has an error that requires the user to do something.
	pjsRestart,									// Job has been restarted.
	pjsComplete,								// Windows XP and later: Job is sent to the printer, but the job may not be printed yet.
	pjsRetained									// Windows Vista and later: Job has been retained in the print queue and cannot be deleted. Due to:
												// 1) The job was manually retained by a call to SetJob and the spooler is waiting for the job to be released.
												// 2) The job has not finished printing and must finish printing before it can be automatically deleted.
  );
  TPrintJobStatus = set of TPrintJobStatusFlag;

  // Defines things the printer can support. Note that it is entirely up to the printer driver which capability is
  // claimed as being supported. For example, support for duplexing may be reported even when this only works by
  // feeding each page manually into the printer in the correct orientation.
  TPrinterCapability = (
	pcCopies,				// supports printing of multiple copies of each page
	pcOrientation,			// supports printing in portrait and landscape
	pcCollation,			// supports collating (if multiple copies of each page are printed)
	pcColor,				// supports switching between color and monochrome printing (on color printers)
	pcDuplex,				// supports double-sided printing
	pcScale,				// supports scaling of whole output
	pcPaperSource,			// supports selection of paper sources (bins or other means of feeding paper)
	pcPaperSize,			// supports selection of paper sizes (like Letter, A4, etc)
	pcMediaType				// supports selection of media types (like glossy paper, transparent film, etc)
  );
  TPrinterCapabilities = set of TPrinterCapability;


  TPrinterOrientation = (poPortrait, poLandscape);


  // Defines how the back-side of the paper is oriented with respect to the front-side.
  TPrinterDuplexing = (
	pdSimplex,				// normal (nonduplex) printing
	pdVertical,				// long-edge binding, that is, the long edge of the page is vertical.
	pdHorizontal			// short-edge binding, that is, the long edge of the page is horizontal
  );


  TPrinterOption = record
	Name: string;
	ID: uint32;
  end;

  TPrinterOptions = array of TPrinterOption;


  TPrinterPaperSize = record
	Name: string;			// name (like 'A4', 'Letter')
	ID: uint16;				// ID for SelectPaperSize()
	Size: TSize;			// width and height of the paper sheet, in 0.1 mm units
  end;

  TPrinterPaperSizes = array of TPrinterPaperSize;


  // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-logfontw
  // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-textmetricw
  TFontItem = record
  strict private
	function GetOption(Index: int32): boolean; inline;
  public
	Name: string;
	Props: Windows.TLogFont;
	Metric: Windows.TTextMetric;
	property IsFixedPitch: boolean index TMPF_FIXED_PITCH read GetOption;
	property IsVector: boolean     index TMPF_VECTOR read GetOption;
	property IsDeviceFont: boolean index TMPF_DEVICE read GetOption;
	property IsTrueType: boolean   index TMPF_TRUETYPE read GetOption;
  end;
  TFontDynArray = array of TFontItem;


  // Represents a printing target (Windows printer) together with individual settings and at most one active print job.
  // It is possible to have multiple objects for the same Windows printer, each with its own settings, and each with
  // its own active print job.
  // A TPrinterEx object is not bound to a specific thread; methods or properties can be accessed from any thread as
  // long as no two thread are doing this at the same time.
  TPrinterEx = class(TObject)
  strict private
	FName: string;
	FDevMode: PDeviceMode;
	FCanvas: TCanvas;
	FUnitsPerInch: integer;
	FDC: HDC;
	FJobID: uint32;
	FPrinting: boolean;
	FDevModeChanged: boolean;
	FOptimizeResetDC: boolean;
	FPageNumber: integer;
	FCapabilities: TPrinterCapabilities;

	procedure ConvToLoMM(var Size: TSize);
	procedure CreateIC;
	function GetOptions(CapNames, CapIDs: uint16; LenName, LenID: integer): TPrinterOptions;
	class function StrFromBuf(Buf: PChar; Len: integer): string; static;
	procedure CheckCapability(Capability: TPrinterCapability);
	function EndPage: boolean;

	// Property support:
	function GetCollate: boolean;
	procedure SetCollate(Value: boolean);
	function GetColor: boolean;
	procedure SetColor(Value: boolean);
	function GetDuplex: TPrinterDuplexing;
	procedure SetDuplex(Value: TPrinterDuplexing);
	function GetNumCopies: uint16;
	procedure SetNumCopies(Value: uint16);
	function GetOrientation: TPrinterOrientation;
	procedure SetOrientation(Value: TPrinterOrientation);
	function GetScale: uint16;
	procedure SetScale(Value: uint16);
  protected
	property DC: HDC read FDC;
	procedure CheckPrinting(Value: boolean);
  public
	constructor Create(const Name: string);
	destructor Destroy; override;
	procedure Abort;
	function BeginDoc(const JobName: string; const OutputFilename: string = ''): boolean;
	function EndDoc: boolean;
	function NewPage: boolean;
	procedure SetMapMode(MapMode: byte; IgnorePageMargins: boolean);

	property Name: string read FName;
	property Canvas: TCanvas read FCanvas;
	property Capabilities: TPrinterCapabilities read FCapabilities;
	property Collate: boolean read GetCollate write SetCollate;
	property Copies: uint16 read GetNumCopies write SetNumCopies;
	property Duplex: TPrinterDuplexing read GetDuplex write SetDuplex;
	property JobID: uint32 read FJobID;
	property Orientation: TPrinterOrientation read GetOrientation write SetOrientation;
	property PageNumber: integer read FPageNumber;
	property Printing: boolean read FPrinting;
	property Scale: uint16 read GetScale write SetScale;
	property UseColor: boolean read GetColor write SetColor;
	property OptimizeResetDC: boolean read FOptimizeResetDC write FOptimizeResetDC;

	property UnitsPerInch: integer read FUnitsPerInch write FUnitsPerInch;

	property DevMode: PDeviceMode read FDevMode;
	procedure SetDevMode(Value: PDeviceMode);

	function GetPaperSizes: TPrinterPaperSizes;
	procedure SelectPaperSize(ID: uint16);
	procedure SetCustomPaperSize(const Size: TSize);

	function GetPaperSources: TPrinterOptions;
	procedure SelectPaperSource(ID: uint16);

	function GetMediaTypes: TPrinterOptions;
	procedure SelectMediaType(ID: uint32);

	function GetFonts: TStringDynArray;
	function GetFontsEx: TFontDynArray;

	function GetPageSize: TSize;
	function GetPageMargins: TSize;
	function GetPrintableArea: TSize;
	function GetDPI: TSize;

	class function TryCreate(const Name: string): TPrinterEx; static;
	class function PrinterExists(const Name: string): boolean; static;
	class function GetPrinters: TStringDynArray; static;
	class function GetDefaultPrinter: string; static;

	class function SetJob(const PrinterName: string; JobID: uint32; Cmd: TPrintJobCmd): boolean; static;
	class function GetJobStatus(const PrinterName: string; JobID: uint32; out Status: TPrintJobStatus): boolean; static;
  end;


{############################################################################}
implementation
{############################################################################}

uses
  Consts;

const
  JOB_STATUS_COMPLETE = $00001000;
  JOB_STATUS_RETAINED = $00002000;

{$if 1 shl ord(pjsPaused)   <> JOB_STATUS_PAUSED}   {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsError)    <> JOB_STATUS_ERROR}    {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsDeleting) <> JOB_STATUS_DELETING} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsSpooling) <> JOB_STATUS_SPOOLING} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsPrinting) <> JOB_STATUS_PRINTING} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsOffline)  <> JOB_STATUS_OFFLINE}  {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsPaperout) <> JOB_STATUS_PAPEROUT} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsPrinted)  <> JOB_STATUS_PRINTED}  {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsDeleted)  <> JOB_STATUS_DELETED}  {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsBlocked)  <> JOB_STATUS_BLOCKED_DEVQ} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsIntervention) <> JOB_STATUS_USER_INTERVENTION} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsRestart)  <> JOB_STATUS_RESTART}  {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsComplete) <> JOB_STATUS_COMPLETE} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}
{$if 1 shl ord(pjsRetained) <> JOB_STATUS_RETAINED} {$message error 'TPrintJobStatusFlag is wrong'} {$ifend}

type
  TFontEnum = record
	Names: TStringDynArray;
	Count: integer;
  end;
  TFontEnumEx = record
	Items: TFontDynArray;
	Count: integer;
  end;


function _IsValidDevmode(pDevmode: PDeviceMode; DevmodeSize: UINT_PTR): BOOL; stdcall;
 external WinSpool.winspl name {$ifdef UNICODE}'IsValidDevmodeW'{$else}'IsValidDevmodeA'{$endif};

function _GetDefaultPrinter(DefaultPrinter: PChar; var I: DWORD): BOOL; stdcall;
 external WinSpool.winspl name {$ifdef UNICODE}'GetDefaultPrinterW'{$else}'GetDefaultPrinterA'{$endif};


procedure RaiseError(const Msg: string);
begin
  raise EPrinter.Create(Msg);
end;

procedure RaiseInvalidParamError;
begin
  raise EArgumentOutOfRangeException.Create('Value out of range');
end;

procedure ChkGdiErr(Cond: boolean);
begin
  if not Cond then RaiseError('GDI or printer driver error');
end;

procedure RaiseOSError(Err: DWORD);
begin
  RaiseError(SysUtils.SysErrorMessage(Err));
end;

procedure Win32Check(Cond: boolean);
begin
  if not Cond then RaiseOSError(Windows.GetLastError);
end;

 // In contrast to Assert(), the code for calculating the argument is not removed in RELEASE mode.
procedure MyAssert(Cond: boolean); inline;
begin
  Assert(Cond);
end;


{ TFontItem }

 //===================================================================================================================
 // Support for properties:
 //===================================================================================================================
function TFontItem.GetOption(Index: int32): boolean;
begin
  Result := self.Metric.tmPitchAndFamily and byte(Index) <> 0;
end;


{ TPrinterCanvas }

type
  TPrinterCanvas = class sealed (TCanvas)
  strict private
	FPrinter: TPrinterEx;
  strict protected
	procedure Changing; override;
	procedure CreateHandle; override;
  private
	procedure UpdateFont;
  public
	constructor Create(Printer: TPrinterEx);
  end;


 //===================================================================================================================
 //===================================================================================================================
constructor TPrinterCanvas.Create(Printer: TPrinterEx);
begin
  inherited Create;
  FPrinter := Printer;
  // this value only changes afterwards if the application explicitly changes it:
  self.Font.PixelsPerInch := FPrinter.UnitsPerInch;
end;


 //===================================================================================================================
 // Is called by TCanvas normally at most once per page (as long as .Handle is not set to zero).
 // Should not cause the resources (Font, Pen, Brush) to be selected into the canvas at this point. This happens
 // afterwards in TCanvas.RequiredState() when requested.
 //===================================================================================================================
procedure TPrinterCanvas.CreateHandle;
begin
  Assert(FPrinter.DC <> 0);
  Assert(not self.HandleAllocated);
  self.Handle := FPrinter.DC;
end;


 //===================================================================================================================
 // Called by TCanvas before every drawing operation as also from GetHandle, but unfortunately not before
 // TCanvas.TextExtent:
 //===================================================================================================================
procedure TPrinterCanvas.Changing;
begin
  // allow Canvas to be used only when there is a print job:
  FPrinter.CheckPrinting(true);
  inherited;
end;


 //===================================================================================================================
 // Force Font.PixelsPerInch to match the Y resolution of the printer.
 //===================================================================================================================
procedure TPrinterCanvas.UpdateFont;
begin
  if self.Font.PixelsPerInch <> FPrinter.UnitsPerInch then begin
	// updating Font.Height is not really important, but done for consistency before/after SetMapMode calls:
	self.Font.Height := MulDiv(self.Font.Height, FPrinter.UnitsPerInch, self.Font.PixelsPerInch);
	// this is important:
	self.Font.PixelsPerInch := FPrinter.UnitsPerInch;
  end;
end;


{ TPrinterEx }

 //===================================================================================================================
 // If the given printer exists, a new object is created and returned. If no such printer exists, nil is returned and
 // Windows.GetLastError can be queried.
 //===================================================================================================================
class function TPrinterEx.TryCreate(const Name: string): TPrinterEx;
begin
  // validating <Name> before construction:
  if TPrinterEx.PrinterExists(Name) then
	Result := TPrinterEx.Create(Name)
  else
	Result := nil;
end;


 //===================================================================================================================
 // <Name> may be the name of a local printer or the UNC name of a shared printer in the form \\server\printername.
 // For an invalid name, an EPrinter exception is raised.
 //===================================================================================================================
constructor TPrinterEx.Create(const Name: string);
begin
  inherited Create;
  FName := Name;

  // validates FName and allocates FDevMode:
  self.SetDevMode(nil);
  Assert(FDevMode <> nil);

  // create the Canvas object and adjust Canvas.Font.PixelsPerInch:
  FUnitsPerInch := self.GetDPI.cy;
  FCanvas := TPrinterCanvas.Create(self);
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TPrinterEx.Destroy;
begin
  self.Abort;
  FCanvas.Free;

  if FDC <> 0 then
	MyAssert(Windows.DeleteDC(FDC));

  FreeMem(FDevMode);
  inherited;
end;


 //===================================================================================================================
 // Provides a device context using the current content of FDevMode, or updates it.
 //===================================================================================================================
procedure TPrinterEx.CreateIC;
begin
  if FDC = 0 then begin
	FDC := Windows.CreateIC(nil, PChar(FName), nil, FDevMode);
	ChkGdiErr(FDC <> 0);
	FDevModeChanged := false;
  end
  else if FDevModeChanged and not FPrinting then begin
	ChkGdiErr(Windows.ResetDC(FDC, FDevMode^) <> 0);
	FDevModeChanged := false;
  end;
end;


 //===================================================================================================================
 // This defines the unit of measure ("logical unit") used by all TCanvas operations, including the dimensions of the
 // font, pen and brush used by this TCanvas object.
 // Can be called with MM_TEXT, MM_HIENGLISH, MM_HIMETRIC, MM_LOENGLISH, MM_LOMETRIC or MM_TWIPS.
 // The standard map mode is MM_TEXT, which uses "pixel" as logical unit.
 // For MM_ANISOTROPIC or MM_ISOTROPIC, you need to create your own method.
 // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setmapmode
 //===================================================================================================================
procedure TPrinterEx.SetMapMode(MapMode: byte; IgnorePageMargins: boolean);
var
  v, w: TSize;
begin
  self.CheckPrinting(true);

  // only GM_ADVANCED supports font scaling for both the X and Y axes independently (see note below):
  ChkGdiErr(Windows.SetGraphicsMode(FDC, GM_ADVANCED) <> 0);
  ChkGdiErr(Windows.SetMapMode(FDC, MapMode) <> 0);

  if MapMode <> MM_TEXT then begin
	// read the viewport and window extent set be <MapMode>:
	ChkGdiErr(Windows.GetWindowExtEx(FDC, w));
	ChkGdiErr(Windows.GetViewPortExtEx(FDC, v));

	// Note: At this pount, you could modify <w> to scale one or both axis.

	// re-adjust the Y axis orientation back to top-down, as in MM_TEXT:
	ChkGdiErr(Windows.SetMapMode(FDC, MM_ANISOTROPIC) <> 0);
	ChkGdiErr(Windows.SetWindowExtEx(FDC, w.cx, w.cy, nil));
	ChkGdiErr(Windows.SetViewPortExtEx(FDC, v.cx, -v.cy, nil));
  end;

  case MapMode of
  MM_TEXT:      FUnitsPerInch := self.GetDPI.cy;
  MM_LOMETRIC:  FUnitsPerInch := 254;
  MM_HIMETRIC:  FUnitsPerInch := 2540;
  MM_LOENGLISH: FUnitsPerInch := 100;
  MM_HIENGLISH: FUnitsPerInch := 1000;
  MM_TWIPS:     FUnitsPerInch := 1440;
  else          RaiseInvalidParamError;
  end;

  if IgnorePageMargins then
	// map the Canvas coordinate (0,0) to the upper left corner of the physical page:
	Windows.SetViewportOrgEx(FDC, -Windows.GetDeviceCaps(FDC, PHYSICALOFFSETX), -Windows.GetDeviceCaps(FDC, PHYSICALOFFSETY), nil)
  else
	// map the Canvas coordinate (0,0) to the upper left corner of the printable area:
	Windows.SetViewportOrgEx(FDC, 0, 0, nil);

  // force FCanvas.Font.PixelsPerInch to match FUnitsPerInch:
  TPrinterCanvas(FCanvas).UpdateFont;
end;


 //===================================================================================================================
 // Throws an EPrinter exception if the printer does not support <Capability>.
 //===================================================================================================================
procedure TPrinterEx.CheckCapability(Capability: TPrinterCapability);
begin
  if not (Capability in FCapabilities) then
	RaiseError('Unsupported by this printer');
end;


 //===================================================================================================================
 // Throws an EPrinter exception if the printer is not in the state requested by <Value>.
 //===================================================================================================================
procedure TPrinterEx.CheckPrinting(Value: boolean);
begin
  if FPrinting <> Value then
	if Value then RaiseError(Consts.SNotPrinting)
	else RaiseError(Consts.SPrinting);
end;


 //===================================================================================================================
 // Starts a print job <JobName> at the printer, optionally redirecting the output to <OutputFilename>.
 // If the printer opens some dialog at this point (for example, 'Microsoft Print to PDF' will do this) and this
 // dialog is cancelled by the user, false is returned.
 // Throws an EPrinter exception if Windows cannot create a print job for whatever reason.
 //===================================================================================================================
function TPrinterEx.BeginDoc(const JobName: string; const OutputFilename: string = ''): boolean;
var
  DocInfo: Windows.TDocInfo;
  JobID: integer;
  ActiveWnd: HWND;
  Reenable: boolean;
begin
  self.CheckPrinting(false);
  FJobID := 0;

  // always start with a fresh DC:
  if FDC <> 0 then begin
	FCanvas.Handle := 0;
	MyAssert(Windows.DeleteDC(FDC));
	FDC := 0;
  end;

  FDC := Windows.CreateDC(nil, PChar(FName), nil, FDevMode);
  ChkGdiErr(FDC <> 0);
  FDevModeChanged := false;

  // The file-selection dialog of "Microsoft Print to PDF" selects a wrong window as its owner (it uses the *owner* of
  // the active window instead of the active window itself). To mitigate this error, we
  // => prevent clicking the still active window
  // => restore the Active state afterwards, as it is wrongly restored by the file selection dialog
  if not System.IsConsole and (Windows.GetCurrentThreadID = System.MainThreadID) then begin
	// only for the GUI thread, not for other threads:
	ActiveWnd := Windows.GetActiveWindow;
	Reenable := (ActiveWnd <> 0) and not Windows.EnableWindow(ActiveWnd, false);
  end
  else begin
	ActiveWnd := 0;
	Reenable := false;
  end;
  try
	FillChar(DocInfo, SizeOf(DocInfo), 0);
	DocInfo.cbSize := SizeOf(DocInfo);
	DocInfo.lpszDocName := PChar(JobName);
	if OutputFilename <> '' then
	  DocInfo.lpszOutput := PChar(OutputFilename);

	// for Print-To-Pdf (or Print-to-File for normal printers), StartDoc() shows a dialog which the user can cancel
	// => handle the error:
	JobID := Windows.StartDoc(FDC, DocInfo);

	if JobID <= 0 then begin
	  // if the dialog was not cancelled by the user, throw an exception:
	  Win32Check(Windows.GetLastError = ERROR_CANCELLED);
	  exit(false);
	end;

	// StartDoc() has created a job in the spooler => enable AbortDoc():
	FJobID := JobID;
	FPrinting := true;

  finally
	if Reenable then Windows.EnableWindow(ActiveWnd, true);
	if ActiveWnd <> 0 then Windows.SetActiveWindow(ActiveWnd);
  end;

  //Assert((FCanvas.PenPos.X = 0) and (FCanvas.PenPos.Y = 0));

  FPageNumber := 1;

  ChkGdiErr(Windows.StartPage(FDC) > 0);
  Result := true;
end;


 //===================================================================================================================
 // Internal: Finishes the current page. Returns false, if the Windows print job was cancelled by some outside action
 // or if there is some other failure with the printing system (spooler, driver).
 // EndPage() seems not to set GetLastError. EndPage() may fail for some incomplete/inconsistent printer + driver setups
 // (then the job definitely fails to print).
 //===================================================================================================================
function TPrinterEx.EndPage: boolean;
begin
  // false => job was cancelled by another program like Windows' Print Queue GUI, using
  // Windows.SetJob(, JOB_CONTROL_DELETE) or Windows.SetPrinter(, PRINTER_CONTROL_PURGE):
  Result := Windows.EndPage(FDC) > 0;
end;


 //===================================================================================================================
 // Finishes the last page and also the printjob. Returns false, if the Windows print job was cancelled by some action
 // outside of this object.
 // After this call, the job is definitely finished (Printing = false). If an error occurred during the call, an EPrinter
 // exception is thrown and the job is automatically aborted.
 //===================================================================================================================
function TPrinterEx.EndDoc: boolean;
begin
  self.CheckPrinting(true);

  try
	Assert(FDC <> 0);
	FCanvas.Handle := 0;

	if not self.EndPage then begin
	  self.Abort;
	  exit(false);
	end;

	ChkGdiErr(Windows.EndDoc(FDC) > 0);

  except
	self.Abort;
	raise;
  end;

  FPrinting := false;
  Result := true;
end;


 //===================================================================================================================
 // Cancels the printjob (if any).
 // For printers that use Print Job Language (https://en.wikipedia.org/wiki/Printer_Job_Language), the Windows spooler
 // tries to cancel the job on the printer; for other printers, it simply stops the data transfer.
 // Since it is used in 'Destroy', it must not throw an exception.
 //===================================================================================================================
procedure TPrinterEx.Abort;
begin
  if FPrinting then begin
	// use AbortDoc() only once and only between StartDoc() and EndDoc():
	FPrinting := false;

	Assert(FDC <> 0);
	FCanvas.Handle := 0;
	Windows.AbortDoc(FDC);
  end;
end;


 //===================================================================================================================
 // Finishes the current page and starts a new one.
 // Applies in-between changes of various properties, like paper orientation, paper size, paper source,
 // number of copies to be printed, duplex mode, and so on.
 // Returns false, if the Windows print job was cancelled by some action outside of this object.
 //===================================================================================================================
function TPrinterEx.NewPage: boolean;
begin
  self.CheckPrinting(true);

  // after ResetDC, the DC may have different properties, so unassociate FCanvas from it:
  FCanvas.Handle := 0;

  if not self.EndPage then
	exit(false);

  // With FOptimizeResetDC, FDevMode is applied to the DC only when needed.
  // With ResetDC, every page starts with the same fresh DC state; by skipping it most of the time, the application
  // must be more careful when using raw GDI calls.
  if not FOptimizeResetDC or FDevModeChanged then begin
	// ResetDC() resets the mapping mode (SetMapMode + SetViewportExtEx + SetWindowExtEx) and the world transformation
	// (SetWorldTransform), the origins (SetViewportOrgEx + SetWindowOrgEx + SetBrushOrgEx), as also the graphics mode
	// (SetGraphicsMode):
	// According to https://referencesource.microsoft.com/#System.Drawing/commonui/System/Drawing/Printing/DefaultPrintController.cs
	// and the docs, ResetDC() always returns the same handle as given.
	ChkGdiErr(Windows.ResetDC(FDC, FDevMode^) <> 0);
	FDevModeChanged := false;

	// ResetDC might have altered the page orientation, and therefore the DPI of the Y axis:
	FUnitsPerInch := self.GetDPI.cy;
	// force FCanvas.Font.PixelsPerInch to match FUnitsPerInch:
	TPrinterCanvas(FCanvas).UpdateFont;
  end;

  ChkGdiErr(Windows.StartPage(FDC) > 0);
  Inc(FPageNumber);

  FCanvas.MoveTo(0, 0);

  Result := true;
end;


 //===================================================================================================================
 // Merges the printer settings contained in <Value> with the current settings.
 // The DEVMODE structure pointed to by <Value> must be compatible with this Windows printer (that is: it must be
 // obtained from the exact same printer driver).
 // The call does not transfer ownership of <Value>.
 // If a print job is currently generated, any changes will be delayed until the next page, otherwise the effect is
 // immediate.
 // The merge uses only those fields from <Value> for which the associated flag in Value.dmFields is set.
 // See: https://learn.microsoft.com/en-us/windows/win32/printdocs/documentproperties, description of DM_IN_BUFFER.
 //
 // The fields of TPrinterEx.DevMode must not be changed directly: This property only exists to give the application
 // access to other content inside this structure.
 //===================================================================================================================
procedure TPrinterEx.SetDevMode(Value: PDeviceMode);
var
  Size: integer;
  Err: DWORD;
begin
  // allocate FDevMode only once:
  if FDevMode = nil then begin

	// According to method GetHdevmodeInternal in
	//   https://referencesource.microsoft.com/#System.Drawing/commonui/System/Drawing/Printing/PrinterSettings.cs
	// we dont need a printer handle for DocumentProperties().
	Size := WinSpool.DocumentProperties(0, 0, PChar(FName), nil, nil, 0);
	if Size < 0 then begin
	  // means printer is not accessible (wrong name, no access rights, deleted meanwhile):
	  Err := Windows.GetLastError;
	  if Err = ERROR_INVALID_HANDLE then Err := ERROR_INVALID_PRINTER_NAME;
	  RaiseOSError(Err);
	end;

	GetMem(FDevMode, Size);
	try
	  Win32Check(WinSpool.DocumentProperties(0, 0, PChar(FName), FDevMode, nil, DM_OUT_BUFFER) >= 0)
	except
	  FreeMem(FDevMode);
	  FDevMode := nil;
	  raise;
	end;

	// determine capabilities of the printer or printer driver:
	FCapabilities := [];
	if FDevMode.dmFields and DM_ORIENTATION <> 0 then
	  Include(FCapabilities, pcOrientation);
	if FDevMode.dmFields and DM_COPIES <> 0 then
	  Include(FCapabilities, pcCopies);
	if FDevMode.dmFields and DM_COLLATE <> 0 then
	  Include(FCapabilities, pcCollation);
	if FDevMode.dmFields and DM_COlOR <> 0 then
	  Include(FCapabilities, pcColor);
	if FDevMode.dmFields and DM_DUPLEX <> 0 then
	  Include(FCapabilities, pcDuplex);
	if FDevMode.dmFields and DM_SCALE <> 0 then
	  Include(FCapabilities, pcScale);
	if FDevMode.dmFields and DM_DEFAULTSOURCE <> 0 then
	  Include(FCapabilities, pcPaperSource);
	if FDevMode.dmFields and DM_PAPERSIZE <> 0 then
	  Include(FCapabilities, pcPaperSize);
	if FDevMode.dmFields and DM_MEDIATYPE <> 0 then
	  Include(FCapabilities, pcMediaType);

  end;

  if Value <> nil then begin
	// basic validation of the given DEVMODE structure:
	ChkGdiErr(_IsValidDevmode(Value, Value.dmSize + Value.dmDriverExtra));
	// merge settings from <Value> with the current settings in FDevMode:
	Win32Check(WinSpool.DocumentProperties(0, 0, PChar(FName), FDevMode, Value, DM_IN_BUFFER or DM_OUT_BUFFER) >= 0);
	FDevModeChanged := true;
  end;
end;


 //===================================================================================================================
 // Property Color: If true, a color printer will produce colored output. If false, it will print black/white.
 //===================================================================================================================
function TPrinterEx.GetColor: boolean;
begin
  CheckCapability(pcColor);

  Result := FDevMode.dmColor = DMCOLOR_COLOR;
end;


 //===================================================================================================================
 // Property Color: If true, a color printer will produce colored output. If false, it will print black/white.
 //===================================================================================================================
procedure TPrinterEx.SetColor(Value: boolean);
begin
  CheckCapability(pcColor);

  Assert(FDevMode.dmFields and DM_COLOR <> 0);
  FDevModeChanged := true;
  if Value then
	FDevMode.dmColor := DMCOLOR_COLOR
  else
	FDevMode.dmColor := DMCOLOR_MONOCHROME;
end;


 //===================================================================================================================
 // Property Collate: If true, multiple copies of pages are collated in separate bins.
 //===================================================================================================================
function TPrinterEx.GetCollate: boolean;
begin
  CheckCapability(pcCollation);

  Result := FDevMode.dmCollate <> DMCOLLATE_FALSE;
end;


 //===================================================================================================================
 // Property Collate: If true, multiple copies of pages are collated in separate bins.
 //===================================================================================================================
procedure TPrinterEx.SetCollate(Value: boolean);
begin
  CheckCapability(pcCollation);

  Assert(FDevMode.dmFields and DM_COLLATE <> 0);
  FDevModeChanged := true;
  if Value then
	FDevMode.dmCollate := DMCOLLATE_TRUE
  else
	FDevMode.dmCollate := DMCOLLATE_FALSE;
end;


 //===================================================================================================================
 // Property Duplex: Controls the mirroring of output on the back of the page.
 //===================================================================================================================
function TPrinterEx.GetDuplex: TPrinterDuplexing;
begin
  CheckCapability(pcDuplex);

  case FDevMode.dmDuplex of
  DMDUP_VERTICAL:   Result := TPrinterDuplexing.pdVertical;
  DMDUP_HORIZONTAL: Result := TPrinterDuplexing.pdHorizontal;
  else              Result := TPrinterDuplexing.pdSimplex;
  end;
end;


 //===================================================================================================================
 // Property Duplex: Controls the mirroring of output on the back of the page.
 //===================================================================================================================
procedure TPrinterEx.SetDuplex(Value: TPrinterDuplexing);
begin
  CheckCapability(pcDuplex);

  Assert(FDevMode.dmFields and DM_COLLATE <> 0);
  FDevModeChanged := true;
  case Value of
  TPrinterDuplexing.pdVertical:   FDevMode.dmDuplex := DMDUP_VERTICAL;
  TPrinterDuplexing.pdHorizontal: FDevMode.dmDuplex := DMDUP_HORIZONTAL;
  else                            FDevMode.dmDuplex := DMDUP_SIMPLEX;
  end;
end;


 //===================================================================================================================
 // Property Copies: Number of copies of each page.
 //===================================================================================================================
function TPrinterEx.GetNumCopies: uint16;
begin
  CheckCapability(pcCopies);

  Result := FDevMode.dmCopies;
end;


 //===================================================================================================================
 // Property Copies: Number of copies of each page.
 //===================================================================================================================
procedure TPrinterEx.SetNumCopies(Value: uint16);
begin
  CheckCapability(pcCopies);

  if (Value <= 0) or (Value > uint16(High(FDevMode.dmCopies))) then
	RaiseInvalidParamError;

  Assert(FDevMode.dmFields and DM_COPIES <> 0);
  FDevModeChanged := true;
  FDevMode.dmCopies := Value;
end;


 //===================================================================================================================
 // Property Orientation: In landscape mode, the printer driver rotates the output by 90° or 270°. Due to this, the
 // application must take into account that the page dimensions are swapped (Width <=> Height).
 //===================================================================================================================
function TPrinterEx.GetOrientation: TPrinterOrientation;
begin
  CheckCapability(pcOrientation);

  if FDevMode.dmOrientation = DMORIENT_PORTRAIT then
	Result := poPortrait
  else
	Result := poLandscape;
end;


 //===================================================================================================================
 // Property Orientation: In landscape mode, the printer driver rotates the output by 90° or 270°. Due to this, the
 // application must take into account that the page dimensions are swapped (Width <=> Height).
 //===================================================================================================================
procedure TPrinterEx.SetOrientation(Value: TPrinterOrientation);
begin
  CheckCapability(pcOrientation);

  Assert(FDevMode.dmFields and DM_ORIENTATION <> 0);
  FDevModeChanged := true;
  if Value = poLandscape then
	FDevMode.dmOrientation := DMORIENT_LANDSCAPE
  else
	FDevMode.dmOrientation := DMORIENT_PORTRAIT;
end;


 //===================================================================================================================
 // Property Scale: Scaling of all output, in percent.
 //===================================================================================================================
function TPrinterEx.GetScale: uint16;
begin
  CheckCapability(pcScale);

  Result := FDevMode.dmScale;
end;


 //===================================================================================================================
 // Property Scale: Scaling of all output, in percent.
 //===================================================================================================================
procedure TPrinterEx.SetScale(Value: uint16);
begin
  CheckCapability(pcScale);

  if Value = 0 then
	RaiseInvalidParamError;

  Assert(FDevMode.dmFields and DM_SCALE <> 0);
  FDevModeChanged := true;
  FDevMode.dmScale := Value;
end;


 //===================================================================================================================
 // Returns all supported options to feed paper into the printer.
 // Returns an empty list if the printer has no concept of "paper sources".
 //===================================================================================================================
function TPrinterEx.GetPaperSources: TPrinterOptions;
var
  i, j: integer;
begin
  Result := self.GetOptions(DC_BINNAMES, DC_BINS, 24, sizeof(WORD));

  // https://stackoverflow.com/questions/71446909/why-does-getsupportedattributevalues-return-paper-types

  // Workaround for a bug in HP PCL drivers which include the names of media types in this list, which fortunately use
  // greater ID values => removing such elements from the result.
  // (The same driver reports a space in front of the names.)
  j := 0;
  for i := Low(Result) to High(Result) do begin
	if Result[i].ID < DMBIN_USER + 256 then begin
	  Result[j] := Result[i];
	  inc(j);
	end;
  end;

  System.SetLength(Result, j);
end;


 //===================================================================================================================
 // Sets the paper source, using the Windows constants DMBIN_xxxxx, or one of the IDs from GetPaperSources.
 //===================================================================================================================
procedure TPrinterEx.SelectPaperSource(ID: uint16);
begin
  CheckCapability(pcPaperSource);

  if (ID <= 0) or (ID > uint16(High(FDevMode.dmDefaultSource))) then
	RaiseInvalidParamError;

  Assert(FDevMode.dmFields and DM_DEFAULTSOURCE <> 0);
  FDevModeChanged := true;
  FDevMode.dmDefaultSource := ID;
end;


 //===================================================================================================================
 // Returns all paper formats supported by the printer, or the paper bin currently selected.
 // Returns an empty list if the printer has no concept of "paper formats".
 // The sizes are reported in 0.1 mm units, for orientation "Portrait" (0° rotation of the output).
 //===================================================================================================================
function TPrinterEx.GetPaperSizes: TPrinterPaperSizes;
const
  NameLen = 64;
type
  TName = array [0..NameLen-1] of char;
var
  Names: array of TName;
  IDs: array of WORD;
  Sizes: array of TPoint;
  Count: integer;
  i: integer;
begin
  Assert(FDevMode <> nil);

  //
  // Retrieve the names:
  //

  Count := WinSpool.DeviceCapabilities(pointer(FName), nil, DC_PAPERNAMES, nil, FDevMode);
  // <DC_PAPERNAMES> may be unsupported or return zero items. There is no way to distingush both conditions
  // (and no need to to this anyway):
  if Count <= 0 then
	exit(nil);

  System.SetLength(Names, Count);
  ChkGdiErr(WinSpool.DeviceCapabilities(pointer(FName), nil, DC_PAPERNAMES, pointer(Names), FDevMode) >= 0);

  //
  // Retrieve the IDs:
  //

  // both lists must match, otherwise its unclear which ID belongs to which name:
  if WinSpool.DeviceCapabilities(pointer(FName), nil, DC_PAPERS, nil, FDevMode) <> Count then
	RaiseError('DeviceCapabilities() returned wrong value');

  System.SetLength(IDs, Count);
  ChkGdiErr(WinSpool.DeviceCapabilities(pointer(FName), nil, DC_PAPERS, pointer(IDs), FDevMode) >= 0);

  //
  // Retrieve the sizes of the paper formats:
  //

  // both lists must match, otherwise its unclear which size belongs to which name:
  if WinSpool.DeviceCapabilities(pointer(FName), nil, DC_PAPERSIZE, nil, FDevMode) <> Count then
	RaiseError('DeviceCapabilities() returned wrong value');

  System.SetLength(Sizes, Count);
  ChkGdiErr(WinSpool.DeviceCapabilities(pointer(FName), nil, DC_PAPERSIZE, pointer(Sizes), FDevMode) >= 0);

  // build the Result array:

  System.SetLength(Result, Count);

  for i := 0 to Count - 1 do begin
	Result[i].Name := self.StrFromBuf(Names[i], NameLen);
	Result[i].ID := IDs[i];
	Result[i].Size.cx := Sizes[i].X;
	Result[i].Size.cy := Sizes[i].Y;
  end;
end;


 //===================================================================================================================
 // Sets the paper size, using the Windows constants DMPAPER_xxxxx, or one of the IDs from GetPaperSizes.
 // See comment at SetCustomPaperSize.
 //===================================================================================================================
procedure TPrinterEx.SelectPaperSize(ID: uint16);
begin
  CheckCapability(pcPaperSize);

  if (ID <= 0) or (ID > uint16(High(FDevMode.dmPaperSize))) then
	RaiseInvalidParamError;

  Assert(FDevMode.dmFields and DM_PAPERSIZE <> 0);
  FDevModeChanged := true;
  FDevMode.dmFields := FDevMode.dmFields and not (DM_PAPERWIDTH or DM_PAPERLENGTH);
  FDevMode.dmPaperSize := ID;
end;


 //===================================================================================================================
 // Sets the paper size, in 0.1 mm units.
 // The values reported by GetPageSize and GetPrintableArea are affected by this (and also by .Orientation).
 //
 // (1)
 // The printer driver may select some different paper size, as it sees fit. For example, the driver for Ricoh laser
 // printers (models like "IM C3000") will communicate with the printer to learn the format which is configured at the
 // printer for the specific paper bin, or the driver selects a "fitting" format from a list configured at the Windows
 // printer device.
 //
 // (2)
 // Most of the time, the non-printable margins are not affected by the selected paper size; but its up the printer
 // driver how this is handled. For example, settings the custom page size to 10 x 12 cm on a HP A4 laser printer will
 // give you a printable area of 9.6 x 11.6 cm, even thought a 10x12 area fits completely on A4).
 //===================================================================================================================
procedure TPrinterEx.SetCustomPaperSize(const Size: TSize);
begin
  // Setting a custom paper size is possible even when the printer does not know of any standard paper size
  // (this is a possible by installing a printer with a customized PPD file).
  // There seems to be no indication in Windows if a printer driver allows to set a custom page size.

  if (Size.cx <= 0) or (Size.cx > High(FDevMode.dmPaperWidth)) or (Size.cy <= 0) or (Size.cy > High(FDevMode.dmPaperLength)) then
	RaiseInvalidParamError;

  FDevModeChanged := true;
  FDevMode.dmFields := FDevMode.dmFields or DM_PAPERSIZE or DM_PAPERWIDTH or DM_PAPERLENGTH;
  FDevMode.dmPaperSize := 0;
  FDevMode.dmPaperWidth := Size.cx;
  FDevMode.dmPaperLength := Size.cy;
end;


 //===================================================================================================================
 // Returns all supported media types (like 'HP Edgeline 180g, high-gloss').
 // Returns an empty list if the printer has no concept of "media types".
 //
 // Note that the HP PCL driver may return empty names for the last items in the list: These represent some kind of
 // custom media types (USERDEFINEDMEDIA1 .. USERDEFINEDMEDIA10), as one can see here in the registry:
 // HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers\your-hp-printer\PrinterDriverData\JCTData
 //===================================================================================================================
function TPrinterEx.GetMediaTypes: TPrinterOptions;
const
  DC_MEDIATYPENAMES = 34;
  DC_MEDIATYPES     = 35;
begin
  Result := self.GetOptions(DC_MEDIATYPENAMES, DC_MEDIATYPES, 64, sizeof(DWORD));
end;


 //===================================================================================================================
 // Sets the media type, using the Windows constants DMMEDIA_xxxx, or one of the IDs from GetMediaTypes.
 //===================================================================================================================
procedure TPrinterEx.SelectMediaType(ID: uint32);
begin
  CheckCapability(pcMediaType);

  if ID = 0 then
	RaiseInvalidParamError;

  Assert(FDevMode.dmFields and DM_MEDIATYPE <> 0);
  FDevModeChanged := true;
  FDevMode.dmMediaType := ID;
end;


 //===================================================================================================================
 // Converts <Size> from device pixel to units of 0.1 mm (like mapping mode MM_LOMETRIC).
 //===================================================================================================================
procedure TPrinterEx.ConvToLoMM(var Size: TSize);
begin
  Size.cx := MulDiv(Size.cx, 254, Windows.GetDeviceCaps(FDC, LOGPIXELSX));
  Size.cy := MulDiv(Size.cy, 254, Windows.GetDeviceCaps(FDC, LOGPIXELSY));
end;


 //===================================================================================================================
 // Returns the overall size of the page, including non-printable margins, in 0.1 mm units.
 // When Orientation is poLandscape, the x and y values in the result are swapped.
 //===================================================================================================================
function TPrinterEx.GetPageSize: TSize;
begin
  self.CreateIC;
  Result.cx := Windows.GetDeviceCaps(FDC, PHYSICALWIDTH);
  Result.cy := Windows.GetDeviceCaps(FDC, PHYSICALHEIGHT);
  self.ConvToLoMM(Result);
end;


 //===================================================================================================================
 // Returns the size of the non-printable margins at the left and the top edge of the page, in 0.1 mm units.
 // When Orientation is poLandscape, the x and y values in the result are swapped.
 //===================================================================================================================
function TPrinterEx.GetPageMargins: TSize;
begin
  self.CreateIC;
  Result.cx := Windows.GetDeviceCaps(FDC, PHYSICALOFFSETX);
  Result.cy := Windows.GetDeviceCaps(FDC, PHYSICALOFFSETY);
  self.ConvToLoMM(Result);
end;


 //===================================================================================================================
 // Returns the size of the printable area on the page, in 0.1 mm units.
 // When Orientation is poLandscape, the x and y values in the result are swapped.
 // Any output outside the printable area is clipped off by Windows.
 //
 // Note: By default, GDI shifts all coordinates by (PHYSICALOFFSETX, PHYSICALOFFSETY). This causes Canvas position (0,0)
 // to be the upper-left corner of the printable area, not of the physical page. To print at the same physical location
 // regardless of different non-printable margins at different printers, one needs to shift everyhing to top-left by the
 // result of GetPageMargins, or use SetMapMode() with IgnorePageMargins = true.
 //===================================================================================================================
function TPrinterEx.GetPrintableArea: TSize;
begin
  self.CreateIC;
  Result.cx := Windows.GetDeviceCaps(FDC, HORZRES);
  Result.cy := Windows.GetDeviceCaps(FDC, VERTRES);
  self.ConvToLoMM(Result);
end;


 //===================================================================================================================
 // Returns the physical resolution of the printer in pixels per inch ("Dots Per Inch").
 // When Orientation is poLandscape, the x and y values in the result are swapped.
 // For some printers, the X and Y axis might have a different resolution (for example, Brother specifies
 // 4800 x 1200 dpi for the "MFCJ5855DW" model.)
 //===================================================================================================================
function TPrinterEx.GetDPI: TSize;
begin
  self.CreateIC;
  Result.cx := Windows.GetDeviceCaps(FDC, LOGPIXELSX);
  Result.cy := Windows.GetDeviceCaps(FDC, LOGPIXELSY);
end;


 //===================================================================================================================
 // Used by TPrinterEx.GetFonts.
 //===================================================================================================================
function EnumFontsProc(var LogFont: TLogFont; var TextMetric: TTextMetric; FontType: integer; Ptr: Pointer): integer; stdcall;
var
  Data: ^TFontEnum absolute Ptr;
begin
  if Data.Count >= System.Length(Data.Names) then
	System.SetLength(Data.Names, Data.Count + 1024);
  Data.Names[Data.Count] := LogFont.lfFaceName;
  inc(Data.Count);
  Result := 1;
end;


 //===================================================================================================================
 // Returns all fonts available at this printer, including device-specific fonts.
 //===================================================================================================================
function TPrinterEx.GetFonts: TStringDynArray;
var
  Data: TFontEnum;
begin
  self.CreateIC;
  Data.Count := 0;
  Windows.EnumFonts(FDC, nil, @EnumFontsProc, Pointer(@Data));
  Result := System.Copy(Data.Names, 0, Data.Count);
end;


 //===================================================================================================================
 // Used by TPrinterEx.GetFontsEx.
 //===================================================================================================================
function EnumFontsExProc(var LogFont: TLogFont; var TextMetric: TTextMetric; FontType: integer; Ptr: Pointer): integer; stdcall;
var
  Data: ^TFontEnumEx absolute Ptr;
  Item: ^TFontItem;
begin
  if Data.Count >= System.Length(Data.Items) then
	System.SetLength(Data.Items, Data.Count + 1024);

  Item := @Data.Items[Data.Count];
  Item.Name := LogFont.lfFaceName;
  Item.Props := LogFont;
  Item.Metric := TextMetric;
  inc(Data.Count);
  Result := 1;
end;


 //===================================================================================================================
 // Returns all fonts available at this printer, including device-specific fonts.
 // Unlike GetFont, you also get additional data describing the fonts.
 //===================================================================================================================
function TPrinterEx.GetFontsEx: TFontDynArray;
var
  Data: TFontEnumEx;
begin
  self.CreateIC;
  Data.Count := 0;
  Windows.EnumFonts(FDC, nil, @EnumFontsExProc, Pointer(@Data));
  Result := System.Copy(Data.Items, 0, Data.Count);
end;


 //===================================================================================================================
 // Converts up to <Len> characters from <Buf> into a string.
 //===================================================================================================================
class function TPrinterEx.StrFromBuf(Buf: PChar; Len: integer): string;
var
  i: integer;
begin
  // trim leading spaces (should not be there, but the HP PCL driver is doing this):
  while (Len > 0) and (Buf^ = ' ') do begin
	inc(Buf);
	dec(Len);
  end;
  // Searching the #0 terminator. If all <Len> chars are used, there is none.
  for i := 0 to Len - 1 do begin
	if Buf[i] = #0 then begin
	  Len := i;
	  break;
	end;
  end;
  System.SetString(Result, Buf, Len);
end;


 //===================================================================================================================
 // Retrieves names with corresponding IDs. <LenName> and <LenID> must match the documented values for the respective
 // capability.
 // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-devicecapabilitiesa
 //===================================================================================================================
function TPrinterEx.GetOptions(CapNames, CapIDs: uint16; LenName, LenID: integer): TPrinterOptions;
type
  PUInt16 = ^UInt16;
  PUInt32 = ^UInt32;

  function _IdFromBuf(Buf: PByte; Len: integer): uint32; inline;
  begin
	if Len = 4 then
	  Result := PUInt32(Buf)^
	else
	  Result := PUInt16(Buf)^;
  end;

var
  Names: array of char;
  IDs: array of byte;
  Count: integer;
  i: integer;
  PStr: PChar;
  PID: PByte;
begin
  Assert(FDevMode <> nil);

  //
  // Retrieve the names:
  //

  Count := WinSpool.DeviceCapabilities(pointer(FName), nil, CapNames, nil, FDevMode);
  // <CapNames> may be unsupported or return zero items. There is no way to distingush both conditions (and no need to
  // do this anyway):
  if Count <= 0 then
	exit(nil);

  System.SetLength(Names, Count * LenName);
  ChkGdiErr(WinSpool.DeviceCapabilities(pointer(FName), nil, CapNames, pointer(Names), FDevMode) >= 0);

  //
  // Retrieve the IDs:
  //

  // both lists must match, otherwise its unclear which ID belongs to which name:
  if WinSpool.DeviceCapabilities(pointer(FName), nil, CapIDs, nil, FDevMode) <> Count then
	RaiseError('DeviceCapabilities() returned wrong value');

  System.SetLength(IDs, Count * LenID);
  ChkGdiErr(WinSpool.DeviceCapabilities(pointer(FName), nil, CapIDs, pointer(IDs), FDevMode) >= 0);

  // combine names and IDs in the result:

  System.SetLength(Result, Count);

  PStr := pointer(Names);
  PID := pointer(IDs);
  for i := 0 to Count - 1 do begin
	Result[i].Name := self.StrFromBuf(PStr, LenName);
	Result[i].ID := _IdFromBuf(PID, LenID);
	inc(PStr, LenName);
	inc(PID, LenID);
  end;
end;


 //===================================================================================================================
 // Returns true, if <Name> is the name of an existing local printer or is the UNC name of an existing shared printer
 // (\\server\printername), and the user has the Windows permissions to at least query the printer.
 // If false is returned, Windows.GetLastError can be queried.
 //===================================================================================================================
class function TPrinterEx.PrinterExists(const Name: string): boolean;
var
  Handle: THandle;
begin
  if not WinSpool.OpenPrinter(PChar(Name), Handle, nil) then
	Result := false
  else begin
	WinSpool.ClosePrinter(Handle);
	Result := true;
  end;
end;


 //===================================================================================================================
 // Returns the names of all printers which are locally configured (that is, visible in the Control panel).
 // For remote printers, the returned name has the format \\server\printername (which is accepted by TPrinterEx.Create).
 //
 // Note: The EnumPrinters() call has no support for Active Directoy at all, and instead relies on the outdated
 // "Computer Browser" services. Therefore, PRINTER_ENUM_NETWORK will fail in enterprise environments using Active
 // Directory and therefore disabled Computer Browser services (even "net view /domain:<name>" will fail with error 6118).
 // To get a list of printers offered by Active Directory, one need to use calls from "AdsHlp.h" and the IDirectorySearch
 // interface defined in "Iads.h".
 //===================================================================================================================
class function TPrinterEx.GetPrinters: TStringDynArray;
const
  Flags = PRINTER_ENUM_CONNECTIONS or PRINTER_ENUM_LOCAL;
  Level = 4;	// "If Level is 4, Name should be NULL. The function always queries on the local computer."
				// "When EnumPrinters is called with a PRINTER_INFO_4 data structure, that function queries the
				// registry for the specified information, then returns immediately."
var
  Buffer: pointer;
  BufSize: DWORD;
  NumInfo: DWORD;
  i: integer;
  PrinterInfo: ^WinSpool.TPrinterInfo4;
begin
  BufSize := 0;
  Win32Check(WinSpool.EnumPrinters(Flags, nil, Level, nil, 0, BufSize, NumInfo) or (Windows.GetLastError = ERROR_INSUFFICIENT_BUFFER));
  if BufSize = 0 then exit(nil);

  GetMem(Buffer, BufSize);
  try
	Win32Check(WinSpool.EnumPrinters(Flags, nil, Level, Buffer, BufSize, BufSize, NumInfo));

	System.SetLength(Result, NumInfo);

	PrinterInfo := Buffer;
	for i := 0 to NumInfo - 1 do begin
	  Result[i] := PrinterInfo.pPrinterName;
	  inc(PrinterInfo);
	end;

  finally
	FreeMem(Buffer);
  end;
end;


 //===================================================================================================================
 // Returns the name of the user's default printer, or an empty string if there is currently no default printer defined.
 //===================================================================================================================
class function TPrinterEx.GetDefaultPrinter: string;
var
  len: DWORD;
  DefaultPrinter: array[0..255] of Char;
begin
  Len := System.Length(DefaultPrinter);

  if not _GetDefaultPrinter(DefaultPrinter, Len) then
	Result := ''
  else
	System.SetString(Result, DefaultPrinter, Len - 1);
end;


 //===================================================================================================================
 // Sends the given command for the Windows print job to the spooler.
 // Throws an EOSError exception if <PrinterName> is invalid, or if there is some spooler error.
 // Returns true, if a job <JobID> was found at the printer <PrinterName> and <Cmd> was accepted by the spooler.
 // Returns false, if no job <JobID> was found.
 //
 // Note:
 // The application must have the required permissions on the printer and on the job.
 // Also, the job might already be finisihed and therefore no longer known to the spooler.
 //===================================================================================================================
class function TPrinterEx.SetJob(const PrinterName: string; JobID: uint32; Cmd: TPrintJobCmd): boolean;
var
  hPrinter: THandle;
begin
  Win32Check(WinSpool.OpenPrinter(PChar(PrinterName), hPrinter, nil));
  try
	if not WinSpool.SetJob(hPrinter, JobID, 0, nil, ord(Cmd)) then begin
	  // => ERROR_INVALID_PARAMETER for unknown JobID:
	  Win32Check(Windows.GetLastError = ERROR_INVALID_PARAMETER);
	  exit(false);
	end;
  finally
	WinSpool.ClosePrinter(hPrinter);
  end;
  Result := true;
end;


 //===================================================================================================================
 // Returns true, if a job <JobID> was found at the printer <PrinterName> and <Status> is set.
 // Returns false, if no job <JobID> was found.
 // Throws an EOSError exception if <PrinterName> is invalid, or if there is some spooler error.
 // If <Status> is returned as an empty set, the job is completely stored in the spooler, but the print queue is paused
 // (therefore, no attempt was made so far by the spooler to send the job to the printer).
 //===================================================================================================================
class function TPrinterEx.GetJobStatus(const PrinterName: string; JobID: uint32; out Status: TPrintJobStatus): boolean;
var
  hPrinter: THandle;
  Info: WinSpool.PJobInfo1;
  Bytes: DWORD;
begin
  Win32Check(WinSpool.OpenPrinter(PChar(PrinterName), hPrinter, nil));
  try

	// the allocation includes the strings referenced by JOB_INFO_1:
	Bytes := 1024;
	repeat

	  GetMem(Info, Bytes);
	  try
		if not WinSpool.GetJob(hPrinter, JobID, 1, Info, Bytes, @Bytes) then begin
		  case Windows.GetLastError of
		  ERROR_INVALID_PARAMETER:   exit(false);
		  ERROR_INSUFFICIENT_BUFFER: continue;
		  else                       Win32Check(false);
		  end;
		end;

		// cast DWORD to a set of flags:
		Status := TPrintJobStatus(uint16(Info.Status));
		exit(true);
	  finally
		FreeMem(Info);
	  end;

	until false;

  finally
	WinSpool.ClosePrinter(hPrinter);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
function UnitTest: boolean;

  procedure _SuppressHint(var Dummy);
  begin
  end;

  function _Swap(S: TSize): TSize;
  begin
	Result.cx := S.cy;
	Result.cy := S.cx;
  end;

  function _EqualSize(const a, b: TSize): boolean;
  begin
	Result := (a.cx = b.cx) and (a.cy = b.cy);
  end;

  function _GetTempFile: string;
  const
	inlen = 1024;
  var
	outlen: DWORD;
  begin
	System.SetLength(Result, inlen);
	outlen := Windows.GetTempPath(inlen, PChar(Result));
	Win32Check((outlen > 0) and (outlen < inlen));
	System.SetLength(Result, outlen);
	Result := Result + '\test.pdf';
  end;

const
  Printer = 'Microsoft Print to PDF';
  Page1 = 'Page 1';
  Page2 = 'Page 2';
var
  p: TPrinterEx;
  PageSize: TSize;
  s, m, a: TSize;
  Strings: TStringDynArray;
  Papers: TPrinterPaperSizes;
  Options: TPrinterOptions;
  Fonts: TFontDynArray;
  f: TFont;
  Status: TPrintJobStatus;
begin
  _SuppressHint(Status);

  TPrinterEx.GetDefaultPrinter;

  Assert(not TPrinterEx.PrinterExists('') and (Windows.GetLastError = ERROR_INVALID_PRINTER_NAME));

  Assert(not TPrinterEx.SetJob(Printer, 123456, pjcPause) );
  Assert(not TPrinterEx.GetJobStatus(Printer, 123456, Status));

  // will raise an "invalid printer name" exception:
  // TPrinterEx.Create('');

  p := TPrinterEx.Create(Printer);

  p.GetDPI;

  //p.Collate;
  //p.Duplex;

  //p.SetPaperSource(DMBIN_FIRST);
  //p.SetPaperSize(DMPAPER_A4);
  //p.SetMediaType(DMMEDIA_STANDARD);

  Papers := p.GetPaperSizes;
  Options := p.GetPaperSources;
  Options := p.GetMediaTypes;
  Strings := p.GetFonts;
  Fonts := p.GetFontsEx;
  if Fonts[0].IsDeviceFont then;
  p.SetDevMode(p.DevMode);

  p.SelectPaperSize(DMPAPER_A3);
  s := p.GetPageSize;
  m := p.GetPageMargins;
  a := p.GetPrintableArea;

  // set paper size to A4 format:
  PageSize.cx := 210 * 10;
  PageSize.cy := 297 * 10;
  p.Orientation := poPortrait;
  p.SetCustomPaperSize(PageSize);
  s := p.GetPageSize;
  m := p.GetPageMargins;
  a := p.GetPrintableArea;
  Assert(_EqualSize(s, PageSize));

  // poLandscape swaps all the infos:
  p.Orientation := poLandscape;
  Assert(_EqualSize(s, _Swap(p.GetPageSize)));
  Assert(_EqualSize(m, _Swap(p.GetPageMargins)));
  Assert(_EqualSize(a, _Swap(p.GetPrintableArea)));

  // poLandscape does not swap the meaning of SelectPaperSize + SetCustomPaperSize, only the reported sizes:
  PageSize.cx := 210 * 10;
  PageSize.cy := 297 * 10;
  p.Orientation := poLandscape;
  p.SetCustomPaperSize(PageSize);
  Assert(_EqualSize(s, _Swap(p.GetPageSize)));
  Assert(_EqualSize(m, _Swap(p.GetPageMargins)));
  Assert(_EqualSize(a, _Swap(p.GetPrintableArea)));

  // DMPAPER_A4 is exactly the same as SetCustomPaperSize(210x297)
  p.Orientation := poLandscape;
  p.SelectPaperSize(DMPAPER_A4);
  Assert(_EqualSize(s, _Swap(p.GetPageSize)));

  // create a PDF file:
  p.BeginDoc('Test', _GetTempFile);

  // abort the job:
  p.Abort;

  p.GetDPI;

  // create print job; the spooler will write the generated printer data to the file:
  p.Copies := 2;
  p.UseColor := false;
  p.BeginDoc('Test', _GetTempFile);

  // set logical units to 0.01 mm:
  p.SetMapMode(MM_HIMETRIC, false);
  // dont fill background of text:
  p.Canvas.Brush.Style := bsClear;

  // set font height to exact 10mm:
  p.Canvas.Font.PixelsPerInch := p.UnitsPerInch;
  p.Canvas.Font.Height := 1000;	// 10mm in MM_HIMETRIC (logical unit = 0.01 mm)
  p.Canvas.Font.Color := clRed;

  // draw text inside a frame:
  p.Canvas.Rectangle(1000, 1000, 1000 + p.Canvas.TextWidth(Page1), 1000 + p.Canvas.TextHeight(Page1));
  p.Canvas.TextOut(1000, 1000, Page1);

  // next page will use paper format A5 in landscape orientation:
  p.Orientation := poLandscape;
  p.SelectPaperSize(DMPAPER_A5);

  p.NewPage;
  p.SetMapMode(MM_HIMETRIC, false);

  // draw text inside a frame:
  p.Canvas.Rectangle(1000, 1000, 1000 + p.Canvas.TextWidth(Page2), 1000 + p.Canvas.TextHeight(Page2));
  p.Canvas.TextOut(1000, 1000, Page2);

  // .Size gets converted by Assign to the printer's resolution, from 22pt (72 dpi) through pixels at 96 dpi to 7.76mm
  // at MM_HIMETRIC (2540 dpi):
  // (96 dpi is the initial value of TFont.PixelsPerInch, as set by the VCL for non-High-DPI GUI apps).
  f := TFont.Create;
  f.Size := 22;
  p.Canvas.Font.Assign(f);
  f.Free;

  // use 7.76mm directly, without conversion from 72 dpi through 96 dpi to 2540 dpi (MM_HIMETRIC):
  f := TFont.Create;
  f.PixelsPerInch := p.UnitsPerInch;
  f.Height := -776;
  p.Canvas.Font.Assign(f);
  f.Free;

  // draw text inside a frame:
  p.Canvas.Rectangle(1000, 2000, 1000 + p.Canvas.TextWidth(Page2), 2000 + p.Canvas.TextHeight(Page2));
  p.Canvas.TextOut(1000, 2000, Page2);

  Assert(TPrinterEx.GetJobStatus(p.Name, p.JobID, Status) and (pjsSpooling in Status));

  Assert(TPrinterEx.SetJob(p.Name, p.JobID, pjcDelete) );

  Assert(TPrinterEx.GetJobStatus(p.Name, p.JobID, Status) and (pjsDeleting in Status));

  p.EndDoc;

  p.Destroy;

  Strings := TPrinterEx.GetPrinters;

  Result := true;
end;


//initialization
//  Assert(UnitTest);
end.
