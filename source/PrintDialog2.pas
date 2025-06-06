unit PrintDialog2;

{
  TPrintDialog2 - Wrapper for the Windows PrintDlg() function (alternative to VCL's TPrintDialog).
  
  Usage example:

	(1) Shows dialog with persisted settings.
	(2) Print with the selected settings.

	The registry helpers are suppposed to read and write from a key under
	  HKCU\Software\<YourCompany>\<YourApp>\<self.Name>

	procedure TReportForm.btPrintClick(Sender: TObject);
	const
	  RegVal_Printer = 'Printer';
	  RegVal_PrinterCfg = 'PrinterCfg';
	var
	  Dlg: TPrintDialog2;
	  P: TPrinterEx;
	begin
	  ActivateHourglass;
	  try

		Dlg := TPrintDialog2.Create;
		try
		  Dlg.Title := 'Some dialog title';
		  Dlg.Options := [poWarning];
		  // read the last used printer name from the registry (a string):
		  Dlg.PrinterName := ReadRegValue(self, RegVal_Printer, '');
		  // read the last used printer settings from the registry (a TByteDynArray):
		  Dlg.PrinterCfg := ReadRegValue(self, RegVal_PrinterCfg);

		  if not Dlg.Execute(self) then exit;

		  // force repainting of the area covered by the dialog & restore the wait cursor before
		  // printer selection (takes time for remote printers):
		  self.Update;
		  ReactivateHourglass;

		  WriteRegValue(self, RegVal_Printer, Dlg.PrinterName);
		  WriteRegValue(self, RegVal_PrinterCfg, Dlg.PrinterCfg);

		  P := TPrinterEx.Create(Dlg.PrinterName);
		  try
			P.SetDevMode(Dlg.DevMode);
			if pcCollation in P.Capabilities then P.Collate := Dlg.Collate;
			if pcCopies in P.Capabilities then P.Copies := Dlg.Copies;

			if not P.BeginDoc('Some print job name') then exit;

			// P.BeginDoc may have shown a dialog for selecting a target file => 
			// force repainting of the area covered by the dialog & restore the wait cursor before
			// the actual printing:
			self.Update;
			ReactivateCursor;

			self.PrintReport(P, FBitmap);
			P.EndDoc;

		  finally
			P.Destroy;
		  end;

		finally
		  Dlg.Destroy;
		end;


	  finally
		DeactivateHourglass;
	  end;
	end;


  Example for a command-line program:

	procedure ShowPrintDlg;
	const
	  JobTitle = 'Some print job name';
	var
	  Dlg: TPrintDialog2;
	  P: TPrinterEx;
	  PrintableArea: TSize;
	  Copies: uint16;
	  Page: uint16;
	  Copy: uint16;
	  Size: TSize;
	  Txt: string;
	begin
	  Dlg := TPrintDialog2.Create;
	  try
		Dlg.Title := 'Some dialog title';
		Dlg.Options := [poPageNums, poWarning];
		Dlg.PrinterName := 'Microsoft Print to PDF';
		// document has 10 pages:
		Dlg.MinPage := 1;
		Dlg.MaxPage := 10;
		// pre-select the range 2-4:
		Dlg.FromPage := 2;
		Dlg.ToPage := 4;

		if not Dlg.ExecuteInThread(0) then exit;

		P := TPrinterEx.Create(Dlg.PrinterName);
		try
		  // set the printer to the selected configuration:
		  P.SetDevMode(Dlg.DevMode);

		  // handle "Collate" and "Copies":
		  if pcCollation in P.Capabilities then P.Collate := Dlg.Collate;
		  if pcCopies in P.Capabilities then begin
			P.Copies := Dlg.Copies;
			Copies := 1;
		  end
		  else begin
			Copies := Dlg.Copies;
		  end;

		  // get area in 0.1 mm:
		  PrintableArea := P.GetPrintableArea;

		  // print the selected pages, each as many times as requested:
		  for Page := Dlg.FromPage to Dlg.ToPage do begin
			for Copy := 1 to Copies do begin
			  if P.Printing then P.NewPage
			  else if not P.BeginDoc(JobTitle) then exit;
			  // set unit of measure to 0.1 mm, as used in <PrintableArea>:
			  P.SetMapMode(MM_LOMETRIC, false);

			  // text height: 50.0 mm
			  Txt := Format('- Page %u -', [Page]);
			  P.Canvas.Font.Height := 500;
			  P.Canvas.Font.Color := clBlue;
			  Size := P.Canvas.TextExtent(Txt);
			  P.Canvas.TextOut((PrintableArea.cx - Size.cx) div 2, (PrintableArea.cy - Size.cy) div 2, Txt);

			  // line with: 1.0 mm
			  P.Canvas.Pen.Width := 10;
			  P.Canvas.Pen.Color := clRed;
			  P.Canvas.Brush.Style := bsClear;
			  P.Canvas.Rectangle(0, 0, PrintableArea.cx, PrintableArea.cy);
			end;
		  end;

		  P.EndDoc;

		finally
		  P.Destroy;
		end;

	  finally
		Dlg.Destroy;
	  end;
	end;

}

{$include LibOptions.inc}

interface

uses
  Types,
  Windows,
  CommDlg,
  Controls;

type
  TPrintRange = (prAllPages, prSelection, prPageNums);
  TPrintDialogOption = (poPrintToFile, poPageNums, poSelection, poWarning, poHelp, poDisablePrintToFile);
  TPrintDialogOptions = set of TPrintDialogOption;


  // Same as TPrintDialog(Ex), but:
  // * Cannot be placed on a Form at design time.
  // * Does not depend on a specific Delphi printer wrapper.
  //
  // Note: The properties Copies and Collate have counterparts on the Printer object. If the printer driver supports it,
  // both functions could be performed by the driver instead of the application. As implemented, the dialog always sets
  // DevMode.dmCopies to 1 and DevMode.dmCollate to 0, and returns the user's choice in its own properties. This leaves
  // it to the application to implement this itself, or to set the printer properties (if the printer driver supports
  // this settings).
  TPrintDialog2 = class
  strict private
	FPrinterName: string;
	FTitle: string;
	FOptions: TPrintDialogOptions;
	FPrintRange: TPrintRange;

	FDevMode: Windows.PDeviceMode;
	FData: CommDlg.TPrintDlg;

	procedure FreeDevMode;
	class procedure FreeGlobal(var Mem: HGLOBAL); static;
	class function DialogHook(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): UINT_PTR; stdcall; static;

	// property support:
	function GetCollate: boolean; inline;
	procedure SetCollate(Value: boolean);
	function GetPrintToFile: boolean; inline;
	procedure SetDevMode(DevMode: PDeviceMode);
	function GetPrinterCfg: TByteDynArray;
	procedure SetPrinterCfg(const Value: TByteDynArray);
  public
	destructor Destroy; override;
	function ExecuteInThread(ParentWnd: HWND): boolean;
	function Execute(Parent: TControl): boolean;

	property PrinterName: string read FPrinterName write FPrinterName;
	property PrinterCfg: TByteDynArray read GetPrinterCfg write SetPrinterCfg;
	property DevMode: PDeviceMode read FDevMode write SetDevMode;

	property Collate: boolean read GetCollate write SetCollate;
	property Copies: uint16 read FData.nCopies write FData.nCopies;
	property FromPage: uint16 read FData.nFromPage write FData.nFromPage;
	property ToPage: uint16 read FData.nToPage write FData.nToPage;
	property MinPage: uint16 read FData.nMinPage write FData.nMinPage;
	property MaxPage: uint16 read FData.nMaxPage write FData.nMaxPage;
	property Options: TPrintDialogOptions read FOptions write FOptions;
	property PrintToFile: boolean read GetPrintToFile;
	property PrintRange: TPrintRange read FPrintRange write FPrintRange;
	property DlgTemplate: PChar read FData.lpPrintTemplateName write FData.lpPrintTemplateName;
	property DlgTemplateModule: HINST read FData.hInstance write FData.hInstance;
	property Title: string read FTitle write FTitle;
  end;


{############################################################################}
implementation
{############################################################################}

uses
  Messages,
  WinSpool,
  MultiMon,
  SysUtils,
  Forms,
  Math;

function _IsValidDevmode(pDevmode: PDeviceMode; DevmodeSize: UINT_PTR): BOOL; stdcall;
 external WinSpool.winspl name {$ifdef UNICODE}'IsValidDevmodeW'{$else}'IsValidDevmodeA'{$endif};

function DupMem(Ptr: pointer; Size: Integer): pointer;
begin
  GetMem(Result, Size);
  Move(Ptr^, Result^, Size);
end;


{ TPrintDialog2 }

 //===================================================================================================================
 //===================================================================================================================
destructor TPrintDialog2.Destroy;
begin
  self.FreeDevMode;
  inherited;
end;


 //===================================================================================================================
 // Free <FDevMode> if not nil, and set it to nil.
 //===================================================================================================================
procedure TPrintDialog2.FreeDevMode;
begin
  FreeMem(FDevMode);
  FDevMode := nil;
end;


 //===================================================================================================================
 // Free <Mem> if not null, and set it to null.
 //===================================================================================================================
class procedure TPrintDialog2.FreeGlobal(var Mem: HGLOBAL);
begin
  if Mem <> 0 then begin
	Windows.GlobalFree(Mem);
	Mem := 0;
  end;
end;


 //===================================================================================================================
 // Property DevMode: Assigns a copy of <DevMode> to the dialog, to provide persisted printer settings which the
 // dialogs allows to change.
 // Note: You must set .PrinterName always before .DevMode.
 //===================================================================================================================
procedure TPrintDialog2.SetDevMode(DevMode: PDeviceMode);
var
  Size: DWORD;
begin
  self.FreeDevMode;

  if DevMode <> nil then begin
	Size := DevMode.dmSize + DevMode.dmDriverExtra;
	Win32Check(_IsValidDevmode(DevMode, Size));
	FDevMode := DupMem(DevMode, Size);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
function TPrintDialog2.GetPrinterCfg: TByteDynArray;
var
  Size: DWORD;
begin
  Result := nil;
  if FDevMode <> nil then begin
	Size := FDevMode.dmSize + FDevMode.dmDriverExtra;
	System.SetLength(Result, Size);
	System.Move(FDevMode^, pointer(Result)^, Size);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TPrintDialog2.SetPrinterCfg(const Value: TByteDynArray);
begin
  if (System.Length(Value) <> 0) and (System.Length(Value) < sizeof(TDeviceMode)) then
	raise Exception.Create('PrinterCfg: Invalid');

  self.SetDevMode(pointer(Value));
end;


 //===================================================================================================================
 // Property Collate: Returns the current value from the dialog.
 //===================================================================================================================
function TPrintDialog2.GetCollate: boolean;
begin
  Result := FData.Flags and PD_COLLATE <> 0;
end;


 //===================================================================================================================
 // Property Collate: Sets the value to be displayed in the dialog.
 //===================================================================================================================
procedure TPrintDialog2.SetCollate(Value: boolean);
begin
  if Value then FData.Flags := FData.Flags or PD_COLLATE
  else FData.Flags := FData.Flags and not PD_COLLATE;
end;


 //===================================================================================================================
 // Property PrintToFile: Returns the current value from the dialog.
 //===================================================================================================================
function TPrintDialog2.GetPrintToFile: boolean;
begin
  Result := FData.Flags and PD_PRINTTOFILE <> 0;
end;


 //===================================================================================================================
 // Shows the dialog without any interaction with the VCL (therefore, this can be called from any thread).
 // Returns false, if the dialog was cancelled by the user.
 //===================================================================================================================
function TPrintDialog2.ExecuteInThread(ParentWnd: HWND): Boolean;

  // create memory blocks for FData.hDevMode and for FData.hDevNames
  procedure _WrapHandles;
  var
	Size: DWORD;
	tmp: PDeviceMode;
	DevNames: PDevNames;
  begin
	Assert(FData.hDevMode = 0);
	Assert(FData.hDevNames = 0);

	if FDevMode <> nil then begin

	  Size := FDevMode.dmSize + FDevMode.dmDriverExtra;

	  FData.hDevMode := Windows.GlobalAlloc(GMEM_MOVEABLE, Size);
	  Win32Check(FData.hDevMode <> 0);

	  tmp := Windows.GlobalLock(FData.hDevMode);
	  try
		System.Move(FDevMode^, tmp^, Size);
	  finally
		Windows.GlobalUnlock(FData.hDevMode);
	  end;

	end;

	Size := System.Length(FPrinterName);

	FData.hDevNames := Windows.GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, sizeof(TDevNames) + (Size + 1) * sizeof(Char));
	Win32Check(FData.hDevNames <> 0);

	DevNames := Windows.GlobalLock(FData.hDevNames);
	try
	  // Ptr to PrinterName + #0
	  DevNames.wDeviceOffset := sizeof(TDevnames) div sizeof(char);
	  // Ptr to #0:
	  DevNames.wDriverOffset := DevNames.wDeviceOffset + Size;
	  // Ptr to #0:
	  DevNames.wOutputOffset := DevNames.wDriverOffset;
	  System.Move(PChar(FPrinterName)^, PChar(DevNames)[DevNames.wDeviceOffset], Size * sizeof(char));
	finally
	  Windows.GlobalUnlock(FData.hDevNames);
	end;
  end;

  // extract content from FData.hDevMode and from FData.hDevNames
  procedure _UnwrapHandles;
  var
	tmp: PDeviceMode;
	DevNames: PDevNames;
  begin
	self.FreeDevMode;
	FPrinterName := '';

	if FData.hDevMode <> 0 then begin
	  tmp := Windows.GlobalLock(FData.hDevMode);
	  try
		FDevMode := DupMem(tmp, tmp.dmSize + tmp.dmDriverExtra);
	  finally
		Windows.GlobalUnlock(FData.hDevMode);
	  end;
	end;

	if FData.hDevNames <> 0 then begin
	  DevNames := PDevNames(Windows.GlobalLock(FData.hDevNames));
	  try
		FPrinterName := PChar(DevNames) + DevNames.wDeviceOffset;
	  finally
		Windows.GlobalUnlock(FData.hDevNames);
	  end;
	end;
  end;

const
  PrintRanges: array [TPrintRange] of Integer = (PD_ALLPAGES, PD_SELECTION, PD_PAGENUMS);
var
  Flags: DWORD;
  Err: DWORD;
  {$ifdef CPUX86}
  FPUControlWord: Word;
  {$endif}
begin
  FData.lStructSize := SizeOf(FData);

  // PD_USEDEVMODECOPIESANDCOLLATE:
  // "Set this flag on input to indicate that your application does not support multiple copies and collation"
  // "If this flag is not set, DEVMODE.dmCopies always returns 1, and DEVMODE.dmCollate is always zero."

  Flags := PrintRanges[FPrintRange] or PD_ENABLEPRINTHOOK;
  if not (poPrintToFile in FOptions) then Flags := Flags or PD_HIDEPRINTTOFILE;
  if not (poPageNums in FOptions) then Flags := Flags or PD_NOPAGENUMS;
  if not (poSelection in FOptions) then Flags := Flags or PD_NOSELECTION;
  if poDisablePrintToFile in FOptions then Flags := Flags or PD_DISABLEPRINTTOFILE;
  if poHelp in FOptions then Flags := Flags or PD_SHOWHELP;
  if not (poWarning in FOptions) then Flags := Flags or PD_NOWARNING;
  if FData.lpPrintTemplateName <> nil then Flags := Flags or PD_ENABLEPRINTTEMPLATE;

  FData.Flags := (FData.Flags and (PD_COLLATE or PD_PRINTTOFILE)) or Flags;

  pointer(FData.lCustData) := self;
  FData.lpfnPrintHook := self.DialogHook;
  FData.hWndOwner := ParentWnd;

  // "Note that the values of hDevMode and hDevNames in PRINTDLG may change when they are passed into PrintDlg."
  // FDevMode.dmDeviceName is limited to 32 chars, but hDevNames has no such limit.
  // If an invalid name is given, the dialog replaces it with the user's default printer when the dialog is shown.

  _WrapHandles;
  {$ifdef CPUX86}
  asm
	// Avoid FPU control word change
	FNSTCW FPUControlWord
  end;
  {$endif}
  try

	if not CommDlg.PrintDlg(FData) then begin
	  // cancelled by user, or by some system error:
	  Err := CommDlg.CommDlgExtendedError;
	  if Err <> 0 then
		raise Exception.CreateFmt('PrintDlg error %u', [Err]);
	  exit(false);
	end;

	// read back the changed values:
	_UnwrapHandles;

  finally
	{$ifdef CPUX86}
	asm
	  FNCLEX
	  FLDCW FPUControlWord
	end;
	{$endif}
	self.FreeGlobal(FData.hDevNames);
	self.FreeGlobal(FData.hDevMode);
  end;

  // FData.hDevNames:  "When PrintDlg returns, the DEVNAMES members contain information for the printer chosen by the user"
  // FData.hDevMode: "When PrintDlg returns, the DEVMODE members indicate the user's input."

  if FData.Flags and PD_SELECTION <> 0 then FPrintRange := prSelection
  else if FData.Flags and PD_PAGENUMS <> 0 then FPrintRange := prPageNums
  else begin
	FPrintRange := prAllPages;
	// auto-update FromPage and ToPage to reflect this selection:
	FData.nFromPage := FData.nMinPage;
	FData.nToPage := FData.nMaxPage;
  end;

  Result := true;
end;


 //===================================================================================================================
 // Shows the dialog like a VCL modal dialog. Must only be called from the main thread.
 // Returns false, if the dialog was cancelled by the user.
 //===================================================================================================================
function TPrintDialog2.Execute(Parent: TControl): boolean;
var
  ParentForm: TCustomForm;
  Wnd: HWND;
  WindowList: Forms.TTaskWindowList;
  FocusState: Forms.TFocusState;
begin
  Assert(Windows.GetCurrentThreadId = System.MainThreadID);

  ParentForm := Forms.GetParentForm(Parent);
  if (ParentForm <> nil) and ParentForm.Visible then
	Wnd := ParentForm.Handle
  else begin
	Wnd := Application.ActiveFormHandle;
	if Wnd = 0 then begin
	  if Application.MainFormOnTaskBar and (Application.MainForm <> nil) then
		Wnd := Application.MainFormHandle
	  else
		Wnd := Application.Handle;
	end;
  end;

  FocusState := Forms.SaveFocusState;
  WindowList := Forms.DisableTaskWindows(Wnd);
  try
	Result := self.ExecuteInThread(Wnd);
  finally
	Forms.EnableTaskWindows(WindowList);
	Windows.SetActiveWindow(Wnd);
	Forms.RestoreFocusState(FocusState);
  end;
end;


 //===================================================================================================================
 // Executed before the dialog box is shown: Set the dialog's title and centers it before its parent window.
 //===================================================================================================================
class function TPrintDialog2.DialogHook(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): UINT_PTR;

  // center the <hDialog> window before <hParent>
  procedure _CenterDlg(hDlg, hParent: HWND);
  var
	Rect: TRect;
	Mon: HMONITOR;
	MonInfo: TMonitorInfo;
	WinSize: TSize;
	WinPos: TPoint;
  begin
	if (hParent = 0) or not Windows.IsWindowVisible(hParent) then exit;

	Windows.GetWindowRect(hDlg, Rect);
	WinSize.cx := Rect.Right - Rect.Left;
	WinSize.cy := Rect.Bottom - Rect.Top;

	Windows.GetWindowRect(hParent, Rect);

	WinPos.X := Rect.Left + ((Rect.Right - Rect.Left) - WinSize.cx) div 2;
	WinPos.Y := Rect.Top + ((Rect.Bottom - Rect.Top) - WinSize.cy) div 2;

	Mon := MultiMon.MonitorFromWindow(hParent, MONITOR_DEFAULTTONEAREST);

	MonInfo.cbSize := SizeOf(MonInfo);
	MultiMon.GetMonitorInfo(Mon, @MonInfo);

	Windows.SetWindowPos(
	  hDlg,
	  0,
	  Math.EnsureRange(WinPos.X, MonInfo.rcWork.Left, MonInfo.rcWork.Right - WinSize.cx),
	  Math.EnsureRange(WinPos.Y, MonInfo.rcWork.Top, MonInfo.rcWork.Bottom - WinSize.cy),
	  0,
	  0,
	  SWP_NOACTIVATE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOOWNERZORDER
	);
  end;

  procedure _SetWindowTitle(hDlg: HWND; const Title: string);
  begin
	if Title <> '' then Windows.SendMessage(hDlg, WM_SETTEXT, 0, Windows.LPARAM(PChar(Title)) );
  end;

var
  Data: PPrintDlg absolute lParam;
begin
  if Msg = WM_INITDIALOG then begin
	Assert(Wnd <> 0);
	_CenterDlg(Wnd, Data.hWndOwner);
	_SetWindowTitle(Wnd, TPrintDialog2(Data.lCustData).Title);
  end;
  Result := 0;
end;

end.
