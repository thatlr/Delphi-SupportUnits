unit FixAtomLeak;

{
  Fix for leakage of Atoms and RegisterWindowMessage registrations due to the VCL using global atoms in
  Dialogs.pas (InitGlobals) and Controls.pas (InitControls) and uses dynamically generated names for them.

  The RegisterWindowMessage registrations will stay in the login session forever, which is bad for services
  since the login session used by Windows services persists until the machine is rebooted.

  If the process does not exit normally (crash, killed, ExitProcess), the global atoms also will stay in the
  login session forever.

  As the VCL checks beforehand if a window belongs to the own process, it should use *local* atoms (beside of that, it
  is a conceptual error to use dynamically generated atom names). Or not use atoms at all: Stringified GUIDs and even
  constant names would do the job.

  Supports 32 and 64 bit.


  When needed:

  Only if the "Controls" or the "Dialogs" unit are used somewhere in a project.


  How to use:

  Include it in the .dpr file, before any unit that references "Controls" or "Dialogs", i.e. before "VCLFixPack".


  How it works:

  It intercepts all calls to GlobalAddAtom() from the actual assembly (EXE or DLL) and modifies the content of the
  problematic strings. This only affects Delphi code inside the same assembly (EXE or DLL). No other assembly of the
  process is affected, as also no calls through GetProcAddr.


  https://learn.microsoft.com/en-us/windows/win32/dataxchg/about-atom-tables
  https://cc.embarcadero.com/Item/28963
  https://devblogs.microsoft.com/oldnewthing/20150319-00/?p=44433
  https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerwindowmessagew
}

{$include LibOptions.inc}

interface


{############################################################################}
implementation
{############################################################################}


// Issue with RegisterWindowMessage exists from Delphi6 to Delphi XE, but the atom leak for abnormal terminated
// processes even exists in Delphi 11.3 (Vcl.Controls.pas, line 17005 and 17007).

{$if defined(Delphi6)}

uses Windows;

type
  TCallHook = record
  strict private
  const
	FCurrentProcess = THandle(-1);
  type
	PTrampoline = ^TTrampoline;
	TTrampoline = packed record
	  OpCode: word;
	  {$ifdef CPU64Bits}
	  RelativeIndirectAddr: int32;
	  {$else}
	  IndirectAddr: PPointer;
	  {$endif}
	end;
	TFunc = function (lpString: PChar): ATOM; stdcall;
  class var
	FFuncPtr: pointer;
	class function CheckString(p1, p2: PChar): boolean; static;
	class function HookedGlobalAddAtom(lpString: PChar): ATOM; stdcall; static;
  public
	class procedure HookGlobalAddAtom; static;
	//class procedure UnhookGlobalAddAtom; static;
  end;


 //=============================================================================
 // Returns true if <p1> starts with <p2>. In that case, the reminder of the <p1> string
 // is overwritten with '0' chars.
 // p1: null-terminated string
 // p2: null-terminated string
 //=============================================================================
class function TCallHook.CheckString(p1, p2: PChar): boolean;
begin
  while p2^ <> #0 do begin
	if p1^ <> p2^ then exit(false);
	inc(p1);
	inc(p2);
  end;

  while p1^ <> #0 do begin
	p1^ := '0';
	inc(p1);
  end;

  Result := true;
end;


 //=============================================================================
 // Is executed instead of the orignal GlobalAddAtom() function, and corrects the problematic atom names.
 // For example, the atom name 'ControlOfs00B2000000004DB8' is changed to 'ControlOfs0000000000000000'.
 // The strings in question are normal Delphi strings, therefore WriteProcessMemory is not needed.
 //=============================================================================
class function TCallHook.HookedGlobalAddAtom(lpString: PChar): ATOM; stdcall;
begin
  // 'Delphi': Controls.InitControls (line 15124)
  // 'ControlOfs': Controls.InitControls (line 15126)
  // 'WndProcPtr': Dialogs.InitGlobals (line 6480)
  if not CheckString(lpString, 'Delphi') then
	if not CheckString(lpString, 'ControlOfs') then
	  CheckString(lpString, 'WndProcPtr');

  Result := TFunc(FFuncPtr)(lpString);
end;


// This is unified by the linker with all other references to the same external function (ONLY if the Delphi symbol
// starts with '_' !), in that all unit-specific trampolines (indirect jumps) share the same fixup pointer.
function _GlobalAddAtom(lpString: PChar): ATOM; stdcall; external kernel32 name {$ifdef UNICODE}'GlobalAddAtomW'{$else}'GlobalAddAtomA'{$endif};


 //=============================================================================
 // Starts interception of GlobalAddAtom calls.
 //=============================================================================
class procedure TCallHook.HookGlobalAddAtom;
type
  PULONG_PTR = ^ULONG_PTR;
var
  FixupItem: PPointer;
  NewAddr: pointer;
begin
  NewAddr := Addr(HookedGlobalAddAtom);

  // Delphi calls external function always indirectly, through a pointer in a global fixup table:
  // (https://www.felixcloutier.com/x86/jmp)
  Assert(PTrampoline(@_GlobalAddAtom).OpCode = $25FF);

  // modify the target address (initially set by the Windows loader) in the compiler-generated fixup table:
  // "How is it that WriteProcessMemory succeeds in writing to read-only memory?":
  // https://devblogs.microsoft.com/oldnewthing/20181206-00/?p=100415

  {$ifdef CPU64Bits}
  FixupItem := PPointer(PByte(@_GlobalAddAtom) + sizeof(TTrampoline) + PTrampoline(@_GlobalAddAtom).RelativeIndirectAddr);
  {$else}
  FixupItem := PTrampoline(@_GlobalAddAtom).IndirectAddr;
  {$endif}
  FFuncPtr := FixupItem^;
  Windows.WriteProcessMemory(FCurrentProcess, FixupItem, @NewAddr, sizeof(NewAddr), PULONG_PTR(nil)^);
end;


(*
 //=============================================================================
 // Stops interception of GlobalAddAtom calls. This is only necessary if this unit is linked into a DLL which
 // can be unloaded by the app.
 //=============================================================================
class procedure TCallHook.UnhookGlobalAddAtom;
begin
  if FFuncPtr <> nil then begin
	Windows.WriteProcessMemory(FCurrentProcess, PTrampoline(@_GlobalAddAtom).IndirectAddr, @FFuncPtr, sizeof(FFuncPtr), PDWORD(nil)^);
	FFuncPtr := nil;
  end;
end;
*)


initialization
  TCallHook.HookGlobalAddAtom;

{$ifend}
end.

