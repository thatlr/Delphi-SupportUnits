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
  - All device context properties that are not represented by VCL objects are reset for each page: This means that
	Pen, Brush, Font, CopyMode and TextFlags are retained, but PenPos and everything one can set directly at the GDI
	Device Context (like Mapping Mode, global transformation) start fresh.


  Font sizes:

  TFont have a Size and a Height property, of which Size is device-independend, and Height is expressed in the logical
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
  - TCanvase.TextWidth and the like will correctly use the logical unit set by SetMapMode().
  - For extra precision, use TFont.Height instead of TFont.Size, as this will prevent some rounding error due to .Size
	using a unit of measure of 1/72 inch.
  - If you create TFont objects, set TFont.PixelPerInch to TPrinterEx.UnitsPerInch together with TFont.Height: This will
	cause .Height to be used "as is", without going through a double-conversion via the .Size value from 96 dpi to the
	printer's logical unit.
}

{$include LibOptions.inc}

interface

uses
  Types,
  Windows,
  SysUtils,
  Graphics;

type
  EPrinter = class(Exception);

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


  TFontItem = record
  strict private
	function GetOption(Index: int32): boolean; inline;
  public
	Name: string;
	Props: Windows.TLogFont;
	Metric: WIndows.TTextMetric;
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
  strict private type
	TState = (psIdle, psPrinting, psAborted);
  strict private
	FName: string;
	FDevMode: PDeviceMode;
	FCanvas: TCanvas;
	FUnitsPerInch: integer;
	FDC: HDC;
	FDevModeChanged: boolean;

	FPageNumber: integer;
	FState: TState;
	FCapabilities: TPrinterCapabilities;

	procedure ConvToLoMM(var Size: TSize);
	procedure CreateDC(StartPrint: boolean);
	procedure DeleteDC;
	function GetOptions(CapNames, CapIDs, LenName, LenID: uint16): TPrinterOptions;
	procedure CheckCapability(Capability: TPrinterCapability);

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
	function GetState(State: TState): boolean; inline;
  protected
	property DC: HDC read FDC;
	procedure CheckPrinting(Value: boolean);
  public
	constructor Create(const Name: string);
	destructor Destroy; override;
	procedure Abort;
	procedure BeginDoc(const JobName: string; const OutputFilename: string = '');
	procedure EndDoc;
	procedure NewPage;
	procedure SetMapMode(MapMode: byte);

	property Name: string read FName;
	property Aborted: boolean index psAborted read GetState;
	property Canvas: TCanvas read FCanvas;
	property Capabilities: TPrinterCapabilities read FCapabilities;
	property Collate: boolean read GetCollate write SetCollate;
	property Copies: uint16 read GetNumCopies write SetNumCopies;
	property Duplex: TPrinterDuplexing read GetDuplex write SetDuplex;
	property Orientation: TPrinterOrientation read GetOrientation write SetOrientation;
	property PageNumber: integer read FPageNumber;
	property Printing: boolean index psPrinting read GetState;
	property Scale: uint16 read GetScale write SetScale;
	property UseColor: boolean read GetColor write SetColor;

	property UnitsPerInch: integer read FUnitsPerInch write FUnitsPerInch;

	property DevMode: PDeviceMode read FDevMode;
	procedure SetDevMode(Value: PDeviceMode);

	function GetPaperSizes: TPrinterOptions;
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
  end;


{############################################################################}
implementation
{############################################################################}

uses
  Consts,
  WinSpool;

type
  TFontEnum = record
	Names: TStringDynArray;
	Count: integer;
  end;
  TFontEnumEx = record
	Items: TFontDynArray;
	Count: integer;
  end;


function _IsValidDevmode(pDevmode: PDevMode; DevmodeSize: UINT_PTR): BOOL; stdcall;
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

procedure Win32Check(Cond: boolean);
begin
  if not Cond then RaiseError(SysErrorMessage(Windows.GetLastError));
end;


{ TFontItem }

 //===================================================================================================================
 // Support for properties:
 //===================================================================================================================
function TFontItem.GetOption(Index: int32): boolean;
begin
  Result := self.Props.lfPitchAndFamily and byte(Index) <> 0;
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
end;


 //===================================================================================================================
 // should be called by TCanvas only once per print job:
 //===================================================================================================================
procedure TPrinterCanvas.CreateHandle;
begin
  Assert(FPrinter.DC <> 0);
  self.Handle := FPrinter.DC;
  // update self.Font.PixelPerInch:
  self.UpdateFont;
end;


 //===================================================================================================================
 // Called by TCanvas before every drawing operation as also from GetHandle, but unfortunately not before
 // TCanvas.TextExtent:
 //===================================================================================================================
procedure TPrinterCanvas.Changing;
begin
  // allow Canvas only to be used when there is a print job:
  FPrinter.CheckPrinting(true);
  inherited;
end;


 //===================================================================================================================
 // Adjust the font object to honor FPrinter.UnitsPerInch.
 //===================================================================================================================
procedure TPrinterCanvas.UpdateFont;
begin
  if self.Font.PixelsPerInch <> FPrinter.UnitsPerInch then begin
	// updating Font.Height is not really important, but done for consistency before/after SetMapMode calls:
	self.Font.Height := MulDiv(self.Font.Height, FPrinter.UnitsPerInch, self.Font.PixelsPerInch);
	// this is important:
	self.Font.PixelsPerInch :=  FPrinter.UnitsPerInch;
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
 //===================================================================================================================
constructor TPrinterEx.Create(const Name: string);
begin
  inherited Create;
  FName := Name;

  // validates FName and allocates FDevMode:
  self.SetDevMode(nil);
  Assert(FDevMode <> nil);

  // initially, we are in MM_TEXT:
  FUnitsPerInch := self.GetDPI.cy;
  FCanvas := TPrinterCanvas.Create(self);
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TPrinterEx.Destroy;
begin
  if FDC <> 0 then begin
	Windows.AbortDoc(FDC);
	Windows.DeleteDC(FDC);
  end;

  FCanvas.Free;
  FreeMem(FDevMode);
  inherited;
end;


 //===================================================================================================================
 // Support for the properties Aborted and Printing.
 //===================================================================================================================
function TPrinterEx.GetState(State: TState): boolean;
begin
  Result := FState = State;
end;


 //===================================================================================================================
 // Create the device context using the current content of FDevMode, or update it.
 //===================================================================================================================
procedure TPrinterEx.CreateDC(StartPrint: boolean);
var
  Create: function (lpszDriver, lpszDevice, lpszOutput: PChar; lpdvmInit: PDeviceMode): HDC; stdcall;
begin
  if FDC = 0 then begin
	// create device context:
	if StartPrint then
	  Create := Windows.CreateDC
	else
	  Create := Windows.CreateIC;

	FDC := Create(nil, PChar(FName), nil, FDevMode);
	if FDC = 0 then RaiseError(Consts.SInvalidPrinter);
  end
  else if FDevModeChanged then begin
	Win32Check( Windows.ResetDC(FDC, FDevMode^) <> 0);
  end;
  FDevModeChanged := false;
end;


 //===================================================================================================================
 // Destroy the device context.
 //===================================================================================================================
procedure TPrinterEx.DeleteDC;
begin
  Assert(FDC <> 0);
  FCanvas.Handle := 0;
  Win32Check( Windows.DeleteDC(FDC) );
  FDC := 0;
end;


 //===================================================================================================================
 // This defines the unit of measure ("logical unit") used by all TCanvas operations, including the dimensions of the
 // font, pen and brush used by this TCanvas object.
 // Can be called with MM_TEXT, MM_HIENGLISH, MM_HIMETRIC, MM_LOENGLISH, MM_LOMETRIC or MM_TWIPS:
 // The standard map mode is MM_TEXT, which uses "pixel" as logical unit.
 // For MM_ANISOTROPIC or MM_ISOTROPIC, you need to create your own method.
 // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setmapmode
 //===================================================================================================================
procedure TPrinterEx.SetMapMode(MapMode: byte);
var
  v, w: TSize;
begin
  self.CheckPrinting(true);

  case MapMode of
  MM_TEXT:      FUnitsPerInch := self.GetDPI.cy;
  MM_LOMETRIC:  FUnitsPerInch := 254;
  MM_HIMETRIC:  FUnitsPerInch := 2540;
  MM_LOENGLISH: FUnitsPerInch := 100;
  MM_HIENGLISH: FUnitsPerInch := 1000;
  MM_TWIPS:     FUnitsPerInch := 1440;
  else          RaiseInvalidParamError;
  end;

  // only GM_ADVANCED supports scaling of fonts for both the X and Y axis independent of each other (see note below):
  Win32Check(Windows.SetGraphicsMode(FDC, GM_ADVANCED) <> 0);
  Win32Check(Windows.SetMapMode(FDC, MapMode) <> 0);

  if MapMode <> MM_TEXT then begin
	// read the viewport and window extent set be <MapMode>:
	Win32Check(Windows.GetWindowExtEx(FDC, w));
	Win32Check(Windows.GetViewPortExtEx(FDC, v));

	// Note: At this pount, you could modify <w> to scale one or both axis.

	// re-adjust the Y axis orientation back to top-down, as in MM_TEXT:
	Windows.SetMapMode(FDC, MM_ANISOTROPIC);
	Win32Check(Windows.SetWindowExtEx(FDC, w.cx, w.cy, nil));
	Win32Check(Windows.SetViewPortExtEx(FDC, v.cx, -v.cy, nil));
  end;

  // deselect the font from the DC:
  FCanvas.Refresh;
  // Force FCanvas.Font.PixelsPerInch to match FUnitsPerInch (FCanvas is only allocated once + the VCL seems to expect
  // TCanvas.Font.PixelsPerInch to be the resolution of the device context).
  // TCanvas.Font.PixelsPerInch is used when a font is assigned to the canvas: If source and target font have different
  // PixelsPerInch values, then the .Height of the assigned font is recalculated from its .Size property.
  TPrinterCanvas(FCanvas).UpdateFont;
end;


 //===================================================================================================================
 // Throw exception if the printer does not support <Capability>.
 //===================================================================================================================
procedure TPrinterEx.CheckCapability(Capability: TPrinterCapability);
begin
  if not (Capability in FCapabilities) then
	RaiseError('Unsupported by this printer');
end;


 //===================================================================================================================
 // Throw exception if the printer is not in the state requested by <Value>.
 //===================================================================================================================
procedure TPrinterEx.CheckPrinting(Value: boolean);
begin
  if self.Printing <> Value then
	if Value then RaiseError(Consts.SNotPrinting)
	else RaiseError(Consts.SPrinting);
end;


 //===================================================================================================================
 // Starts a print job <JobName> at the printer, optionally redirecting the output to <OutputFilename>.
 // If the printer opens some dialog at this point (for example, 'Microsoft Print to PDF' will do this) and this
 // dialog is cancelled by the user, an EAbort exception is thrown.
 //===================================================================================================================
procedure TPrinterEx.BeginDoc(const JobName: string; const OutputFilename: string = '');
var
  DocInfo: Windows.TDocInfo;
  err: DWORD;
  ActiveWnd: HWND;
  Reenable: boolean;
begin
  self.CheckPrinting(false);
  // always start with a fresh DC:
  if FDC <> 0 then self.DeleteDC;
  self.CreateDC(true);
  FState := psPrinting;

  FPageNumber := 1;

  // The file-selection dialog of "Microsoft Print to PDF" select a wrong window as its owner (it uses the *owner* of
  // the active window instead of the active window itself). To mitigate this error, we
  // => prevent clicking the still active window
  // => restore the Active state afterwards, as it is wrongly restored by the file selection dialog
  if Windows.GetCurrentThreadID = System.MainThreadID then begin
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
	if (Windows.StartDoc(FDC, DocInfo) <= 0) or (Windows.StartPage(FDC) <= 0) then begin
	  err := Windows.GetLastError;
	  // dont stay in "Printing" state:
	  self.Abort;
	  // throw EAbort if the dialog was cancelled by the user:
	  if err = ERROR_CANCELLED then SysUtils.Abort;
	  RaiseError(SysErrorMessage(err));
	end;
  finally
	if Reenable then Windows.EnableWindow(ActiveWnd, true);
	if ActiveWnd <> 0 then Windows.SetActiveWindow(ActiveWnd);
  end;

  //Assert((FCanvas.PenPos.X = 0) and (FCanvas.PenPos.Y = 0));
end;


 //===================================================================================================================
 // Finishes the last page and also the printjob.
 //===================================================================================================================
procedure TPrinterEx.EndDoc;
begin
  self.CheckPrinting(true);
  try
	Assert(FDC <> 0);
	Win32Check(Windows.EndPage(FDC) > 0);
	Win32Check(Windows.EndDoc(FDC) > 0);
	FCanvas.Handle := 0;
	FState := psIdle;
  except
	self.Abort;
	raise;
  end;
end;


 //===================================================================================================================
 // Cancels the printjob (if any).
 // For printers that use Print Job Language, the Windows spooler tries to cancel the job on the printer; for other
 // printers, it simply stops the data transfer.
 // https://en.wikipedia.org/wiki/Printer_Job_Language
 //===================================================================================================================
procedure TPrinterEx.Abort;
begin
  if FState = psPrinting then begin
	if FDC <> 0 then
	  Win32Check(Windows.AbortDoc(FDC) > 0);
	FCanvas.Handle := 0;
	FState := psAborted;
  end;
end;


 //===================================================================================================================
 // Finishes the current page and starts a new one.
 // This also applies in-between changes of various properties, like paper orientation, paper size, paper source,
 // number of copies to be printed, duplex mode, and so on.
 //===================================================================================================================
procedure TPrinterEx.NewPage;
begin
  self.CheckPrinting(true);
  Win32Check(Windows.EndPage(FDC) > 0);

  // deselect Font+Pen+Brush from DC and adjust the Canvas state:
  FCanvas.Refresh;

  // ResetDC() resets the mapping mode (SetMapMode + SetViewportExtEx + SetWindowExtEx) and the world transformation
  // (SetWorldTransform), the origins (SetViewportOrgEx + SetWindowOrgEx + SetBrushOrgEx), maybe also the graphics mode
  // (SetGraphicsMode):
  Win32Check(Windows.ResetDC(FDC, FDevMode^) <> 0);
  FDevModeChanged := false;

  //Assert((FCanvas.PenPos.X = 0) and (FCanvas.PenPos.Y = 0));

  Win32Check(Windows.StartPage(FDC) > 0);
  Inc(FPageNumber);
end;


 //===================================================================================================================
 // Merges the printer settings contained in <Value> with the current settings.
 // The DEVMODE structure pointed to by <Value> must be compatible with this Windows printer (that is: it must be
 // obtained from the exact same printer driver).
 // The call does not transfer ownership of <Value>.
 // To make the object aware of changes made directly to fields of the DevMode property, use this:
 //   obj.SetDevMode(obj.DevMode);
 //===================================================================================================================
procedure TPrinterEx.SetDevMode(Value: PDeviceMode);
var
  hPrinter: THandle;
begin
  Win32Check( WinSpool.OpenPrinter(PChar(FName), hPrinter, nil) );
  try

	// allocate FDevMode only once:
	if FDevMode = nil then begin

	  GetMem(FDevMode, WinSpool.DocumentProperties(0, hPrinter, PChar(FName), nil, nil, 0));
	  try
		Win32Check( WinSpool.DocumentProperties(0, hPrinter, PChar(FName), FDevMode, nil, DM_OUT_BUFFER) >= 0)
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
	  Win32Check( _IsValidDevmode(Value, Value.dmSize + Value.dmDriverExtra) );
	  // merge settings from <Value> with the current settings in FDevMode:
	  Win32Check( WinSpool.DocumentProperties(0, hPrinter, PChar(FName), FDevMode, Value, DM_IN_BUFFER or DM_OUT_BUFFER) >= 0);
	  FDevModeChanged := true;
	end;

  finally
	WinSpool.ClosePrinter(hPrinter);
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
 // Returns an empty list if the printer do not have a conctept of "paper sources".
 //===================================================================================================================
function TPrinterEx.GetPaperSources: TPrinterOptions;
var
  i, j: integer;
begin
  Result := self.GetOptions(DC_BINNAMES, DC_BINS, 24, sizeof(WORD));

  // https://stackoverflow.com/questions/71446909/why-does-getsupportedattributevalues-return-paper-types

  // Workaround for a bug in HP PCL drivers which include the names of media types in this list, which fortunately use
  // greater ID values => removing such elements from the result.
  // (The same buggy driver reports a space in front of the names.)
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
 // Returns all supported paper formats (like 'Letter', 'A4').
 // Returns an empty list if the printer do not have a conctept of "paper formats".
 //===================================================================================================================
function TPrinterEx.GetPaperSizes: TPrinterOptions;
begin
  Result := self.GetOptions(DC_PAPERNAMES, DC_PAPERS, 64, sizeof(WORD));
end;


 //===================================================================================================================
 // Sets the paper size, using the Windows constants DMPAPER_xxxxx, or one of the IDs from GetPaperSizes.
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
 //===================================================================================================================
procedure TPrinterEx.SetCustomPaperSize(const Size: TSize);
begin
  CheckCapability(pcPaperSize);

  if (Size.cx <= 0) or (Size.cy <= 0) then
	RaiseInvalidParamError;

  Assert(FDevMode.dmFields and DM_PAPERSIZE <> 0);
  FDevModeChanged := true;
  FDevMode.dmFields := FDevMode.dmFields or DM_PAPERWIDTH or DM_PAPERLENGTH;
  FDevMode.dmPaperSize := 0;
  FDevMode.dmPaperWidth := Size.cx;
  FDevMode.dmPaperLength := Size.cy;
end;


 //===================================================================================================================
 // Returns all supported media types (like 'HP Edgeline 180g, high-gloss').
 // Returns an empty list if the printer do not have a conctept of "media types".
 //
 // Note that the HP PCL driver may return empty names for the last items in the list: These represents some kind of
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
 // Converts from device pixel to units of 0.1 mm (like mapping mode MM_LOMETRIC).
 //===================================================================================================================
procedure TPrinterEx.ConvToLoMM(var Size: TSize);
begin
  Size.cx := MulDiv(Size.cx, 254, Windows.GetDeviceCaps(FDC, LOGPIXELSX));
  Size.cy := MulDiv(Size.cy, 254, Windows.GetDeviceCaps(FDC, LOGPIXELSY));
end;


 //===================================================================================================================
 // Returns the overall size of the page (including non-printable margins), in 0.1 mm units.
 //===================================================================================================================
function TPrinterEx.GetPageSize: TSize;
begin
  self.CreateDC(false);
  Result.cx := Windows.GetDeviceCaps(FDC, PHYSICALWIDTH);
  Result.cy := Windows.GetDeviceCaps(FDC, PHYSICALHEIGHT);
  self.ConvToLoMM(Result);
end;


 //===================================================================================================================
 // Returns the size of the non-printable margins at the left and the top edge of the page, in 0.1 mm units.
 //===================================================================================================================
function TPrinterEx.GetPageMargins: TSize;
begin
  self.CreateDC(false);
  Result.cx := Windows.GetDeviceCaps(FDC, PHYSICALOFFSETX);
  Result.cy := Windows.GetDeviceCaps(FDC, PHYSICALOFFSETY);
  self.ConvToLoMM(Result);
end;


 //===================================================================================================================
 // Returns the size of the printable area on the page, in 0.1 mm units.
 //===================================================================================================================
function TPrinterEx.GetPrintableArea: TSize;
begin
  self.CreateDC(false);
  Result.cx := Windows.GetDeviceCaps(FDC, HORZRES);
  Result.cy := Windows.GetDeviceCaps(FDC, VERTRES);
  self.ConvToLoMM(Result);
end;


 //===================================================================================================================
 // Returns the physical resolution of the printer in pixels per inch ("Dots Per Inch").
 // For some printers, the X and Y axis might have a different resolution.
 // (For example, Brother specifies 4800 x 1200 dpi for the "MFCJ5855DW" model.)
 //===================================================================================================================
function TPrinterEx.GetDPI: TSize;
begin
  self.CreateDC(false);
  Result.cx := Windows.GetDeviceCaps(FDC, LOGPIXELSX);
  Result.cy := Windows.GetDeviceCaps(FDC, LOGPIXELSY);
end;


 //===================================================================================================================
 //===================================================================================================================
function EnumFontsProc(var LogFont: TLogFont; var TextMetric: TTextMetric; FontType: integer; Ptr: Pointer): integer; stdcall;
var
  Data: ^TFontEnum absolute Ptr;
begin
  if Data.Count >= System.Length(Data.Names) then
	System.SetLength(Data.Names, Data.Count + 1024);
  Data.Names[Data.Count] := LogFont.lfFaceName;
//  IsDeviceFont := LogFont.lfPitchAndFamily and TMPF_DEVICE <> 0;
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
  self.CreateDC(false);
  Data.Count := 0;
  Windows.EnumFonts(FDC, nil, @EnumFontsProc, Pointer(@Data));
  Result := System.Copy(Data.Names, 0, Data.Count);
end;


 //===================================================================================================================
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
 // Unlike GetFont, you also get all the properties describing the fonts.
 //===================================================================================================================
function TPrinterEx.GetFontsEx: TFontDynArray;
var
  Data: TFontEnumEx;
begin
  self.CreateDC(false);
  Data.Count := 0;
  Windows.EnumFonts(FDC, nil, @EnumFontsExProc, Pointer(@Data));
  Result := System.Copy(Data.Items, 0, Data.Count);
end;


 //===================================================================================================================
 // Retrieves names with corresponding IDs. <LenName> and <LenID> must match the documented values for the respective
 // capability.
 // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-devicecapabilitiesa
 //===================================================================================================================
function TPrinterEx.GetOptions(CapNames, CapIDs, LenName, LenID: uint16): TPrinterOptions;
type
  PUInt16 = ^UInt16;
  PUInt32 = ^UInt32;

  function _StrFromBuf(Buf: PChar; Len: uint16): string;
  var
	i: integer;
  begin
	// trim leading spaces (should not be there, but HP is doing this):
	i := 0;
	while (i < Len) and (Buf[i] = ' ') do inc(i);
	// Searching the #0 terminator. If all <Len> chars are used, there is none.
	for i := i to Len - 1 do begin
	  if Buf[i] = #0 then begin
		Len := i;
		break;
	  end;
	end;
	SetString(Result, Buf, Len);
  end;

  function _IdFromBuf(Buf: PByte; Len: uint16): uint32; inline;
  begin
	if Len = 4 then
	  Result := PUInt32(Buf)^
	else
	  Result := PUInt16(Buf)^;
  end;

var
  hPrinter: THandle;
  CountNames: integer;
  CountIDs: integer;
  Names: array of char;
  IDs: array of byte;
  i: integer;
  PStr: PChar;
  PID: PByte;
begin
  Win32Check( WinSpool.OpenPrinter(PChar(FName), hPrinter, nil) );
  try

	// Retrieve the names:

	CountNames := WinSpool.DeviceCapabilities(pointer(FName), nil, CapNames, nil, FDevMode);
	// <CapNames> may be unsupported or return zero items. There is no way to distingush this (and no need to to this
	// anyway):
	if CountNames <= 0 then
	  exit(nil);

	System.SetLength(Names, CountNames * LenName);
	Win32Check(WinSpool.DeviceCapabilities(pointer(FName), nil, CapNames, pointer(Names), FDevMode) >= 0);

	// Retrieve the IDs:

	CountIDs := WinSpool.DeviceCapabilities(pointer(FName), nil, CapIDs, nil, FDevMode);
	// DC_BINS may be unsupported:
	if CountIDs < 0 then
	  exit(nil);

	// both lists must match, otherwise its unclear which ID belongs to which name:
	if CountIDs <> CountNames then
	  RaiseError('DeviceCapabilities() returned wrong value');

	System.SetLength(IDs, CountIDs * LenID);
	Win32Check(WinSpool.DeviceCapabilities(pointer(FName), nil, CapIDs, pointer(IDs), FDevMode) >= 0);

  finally
	WinSpool.ClosePrinter(hPrinter);
  end;

  // combine names and IDs in the result:

  System.SetLength(Result, CountIDs);

  PStr := pointer(Names);
  PID := pointer(IDs);
  for i := 0 to CountIDs - 1 do begin
	Result[i].Name := _StrFromBuf(PStr, LenName);
	Result[i].ID := _IdFromBuf(PID, LenID);
	inc(PStr, LenName);
	inc(PID, LenID);
  end;
end;


 //===================================================================================================================
 // Returns true, if
 // - <Name> is the name of an existing local printer
 // - <Name> is the UNC name of an existing shared printer (\\server\printername)
 // and the user has the Windows permissions to at least query the printer.
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
  Win32Check( WinSpool.EnumPrinters(Flags, nil, Level, nil, 0, BufSize, NumInfo) or (Windows.GetLastError = ERROR_INSUFFICIENT_BUFFER));
  if BufSize = 0 then exit(nil);

  GetMem(Buffer, BufSize);
  try
	Win32Check( WinSpool.EnumPrinters(Flags, nil, Level, Buffer, BufSize, BufSize, NumInfo) );

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
 // Returns the name of the user's default printer, or empty string if there is currently no default printer defined.
 //===================================================================================================================
class function TPrinterEx.GetDefaultPrinter: string;
var
  len: DWORD;
  DefaultPrinter: array[0..1023] of Char;
begin
  Len := System.Length(DefaultPrinter);

  if not _GetDefaultPrinter(DefaultPrinter, Len) then
	Result := ''
  else
	SetString(Result, DefaultPrinter, Len - 1);
end;


 //===================================================================================================================
 //===================================================================================================================
procedure UnitTest;
const
  Page1 = 'Page 1';
  Page2 = 'Page 2';
var
  p: TPrinterEx;
  s, m, a: TSize;
  Strings: TStringDynArray;
  Options: TPrinterOptions;
  Fonts: TFontDynArray;
  f: TFont;
begin
try
  TPrinterEx.GetDefaultPrinter;

  Assert(not TPrinterEx.PrinterExists('blabla'));

  p := TPrinterEx.Create('Microsoft Print to PDF');

  p.GetDPI;

  //p.Collate;
  //p.Duplex;

  //p.SetPaperSource(DMBIN_FIRST);
  //p.SetPaperSize(DMPAPER_A4);
  //p.SetMediaType(DMMEDIA_STANDARD);

  Options := p.GetPaperSources;
  Options := p.GetPaperSizes;
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
  s.cx := 210 * 10;
  s.cy := 297 * 10;
  p.SetCustomPaperSize(s);
  s := p.GetPageSize;
  m := p.GetPageMargins;
  a := p.GetPrintableArea;

  // create a PDF file containing a single empty page with the default paper size:
  p.BeginDoc('Test', 'C:\TEMP\test.pdf');

  // abort the job:
  p.Abort;

  p.GetDPI;

  // create print job; the spooler will write the generated printer data to the file:
  p.BeginDoc('Test', 'C:\TEMP\test.pdf');

  // set logical units to 0.1 mm:
  p.SetMapMode(MM_HIMETRIC);
  // dont fill background of text:
  p.Canvas.Brush.Style := bsClear;

//  // set font height to exact 10mm:
//  p.Canvas.Font.PixelsPerInch := p.UnitsPerInch;
//  p.Canvas.Font.Height := 1000;	// 10mm in MM_LOMETRIC (logical unit = 0.01 mm)

  p.Canvas.Font.Size := 15;

  // draw text inside a frame:
  p.Canvas.Rectangle(1000, 1000, 1000 + p.Canvas.TextWidth(Page1), 1000 + p.Canvas.TextHeight(Page1));
  p.Canvas.TextOut(1000, 1000, Page1);

  // next page will use paper format A5 in landscape orientation:
  p.Orientation := poLandscape;
  p.SelectPaperSize(DMPAPER_A5);
  p.NewPage;
  p.SetMapMode(MM_HIMETRIC);

  // draw text inside a frame:
  p.Canvas.Rectangle(1000, 1000, 1000 + p.Canvas.TextWidth(Page2), 1000 + p.Canvas.TextHeight(Page2));
  p.Canvas.TextOut(1000, 1000, Page2);

  // .Size gets converted by Assign to the printer's resolution (-29 at 96dpi => -776 for MM_HIMETRIC):
  f := TFont.Create;
  f.Size := 22;
  p.Canvas.Font.Assign(f);
  f.Free;

  // use -776 directly, without conversion from 96dpi to 2540dpi (MM_HIMETRIC)
  f := TFont.Create;
  f.PixelsPerInch := p.UnitsPerInch;
  f.Height := -776;
  p.Canvas.Font.Assign(f);
  f.Free;

  // draw text inside a frame:
  p.Canvas.Rectangle(1000, 2000, 1000 + p.Canvas.TextWidth(Page2), 2000 + p.Canvas.TextHeight(Page2));
  p.Canvas.TextOut(1000, 2000, Page2);

  p.EndDoc;

  p.Destroy;

  Strings := TPrinterEx.GetPrinters;
except
  Windows.DebugBreak;
end;
end;


//initialization
//  UnitTest;
end.
