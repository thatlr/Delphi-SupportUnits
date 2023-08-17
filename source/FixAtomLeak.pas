unit FixAtomLeak;

{
  Fix for leakage of Atoms and RegisterWindowsMessage registrations due to the VCL using global atoms in
  Dialogs.pas (InitGlobals) and Controls.pas (InitControls) and uses dynamically generated names for them.

  The RegisterWindowsMessage registrations will stay in the login session forever, which is bad for services
  since the login session used by Windows services persists until the machine is rebooted.

  If the process does not exit normally (crash, killed, ExitProcess), the global atoms also will stay in the
  login session forever.

  As the VCL checks beforehand if a window belongs to the own process, it should use *local* atoms (beside of that, it
  is a conceptual error to use dynamically generated atom names). Or no uses atoms at all: Stringified GUIDs and even
  constant names would do the job.


  When needed:

  Only if the "Controls" or the "Dialogs" unit are used somewhere in a project.


  How to use:

  Include it in the .dpr file, before any unit that references "Controls" or "Dialogs", i.e. before "VCLFixPack".


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

{$if not defined(D2009)}

  {$message error 'FixAtomLeak: needs Delphi 2009 due to Unicode'}

{$elseif not defined(DelphiXE2)}

  {$if sizeof(pointer) = 8} {$message error 'FixAtomLeak: only for 32bit'} {$ifend}

// should be fixed in Delphi XE2

uses Windows;


type
  TCallHook = record
  strict private
  const
	FCurrentProcess = THandle(-1);
  type
	PBackupBuffer = ^TBackupBuffer;
	TBackupBuffer = array [0..4] of byte;
	TJmpCode = packed record
	  JmpCode: byte;
	  JmpOffset: int32;
	end;
  class var
	FhInst: HMODULE;
	FContAddr: PByte;
	FBackupBuffer: TBackupBuffer;

	class function StartsWith(p1, p2: PWideChar; Len2: uint32): boolean; static;
	class function HookedGlobalAddAtom(lpString: PWideChar): ATOM; stdcall; static;
  public
	class procedure HookGlobalAddAtom; static;
	class procedure UnhookGlobalAddAtom; static;
  end;


 //=============================================================================
 // Returns true if <p1> matches <p2> in the first <Len2> characters. In that case, the reminder
 // of the <p1> string is overwritten with '0' chars.
 // p1: null-terminated string
 // p2: must not contain a null character within <Len2>
 //=============================================================================
class function TCallHook.StartsWith(p1, p2: PWideChar; Len2: uint32): boolean;
begin
  repeat
	if p1^ <> p2^ then exit(false);
	dec(Len2);
	if Len2 = 0 then break;
	inc(p1);
	inc(p2);
  until false;

  repeat
	inc(p1);
	if p1^ = #0 then break;
	p1^ := '0';
  until false;

  Result := true;
end;


 //=============================================================================
 // Is executed instead of the orignal GlobalAddAtomW() function, to correct the problematic atom names.
 // For example: Changes the dynamically generated atom name 'ControlOfs00B2000000004DB8' by assigning the parameter
 // <lpString> a reference to the static string 'ControlOfs!'.
 //=============================================================================
class function TCallHook.HookedGlobalAddAtom(lpString: PWideChar): ATOM; stdcall;
const
  // Controls.InitControls (line 15124)
  Name1: array [0..5] of WideChar = 'Delphi';
  Name1Len = System.Length(Name1);

  // Controls.InitControls (line 15126)
  Name2: array [0..9] of WideChar = 'ControlOfs';
  Name2Len = System.Length(Name2);

  // Dialogs.InitGlobals (line 6480)
  Name3: array [0..9] of WideChar = 'WndProcPtr';
  Name3Len = System.Length(Name2);
asm
  PUSH EAX
  PUSH EDX
  PUSH ECX

  // EAX := lpString
  // EDX := AtomName
  // ECX := Length(AtomName)

  MOV EAX, lpString
  LEA EDX, Name1
  MOV ECX, Name1Len
  CALL StartsWith
  TEST AL, AL
  JNZ @Found

  MOV EAX, lpString
  LEA EDX, Name2
  MOV ECX, Name2Len
  CALL StartsWith
  TEST AL, AL
  JNZ @Found

  MOV EAX, lpString
  LEA EDX, Name3
  MOV ECX, Name3Len
  CALL StartsWith

@Found:
  POP ECX
  POP EDX
  POP EAX
  JMP [FContAddr];
end;


 //=============================================================================
 // Enables interception of GlobalAddAtomW calls.
 //=============================================================================
class procedure TCallHook.HookGlobalAddAtom;
var
  p: PByte;
  Buffer: TJmpCode;
begin
  FhInst := Windows.LoadLibrary(Windows.kernel32);
  Assert(FhInst <> 0);

  p := Windows.GetProcAddress(FhInst, 'GlobalAddAtomW');
  Assert(p <> nil);

  // save the starting 5 bytes:
  FBackupBuffer := PBackupBuffer(p)^;

  // overwrite the starting 5 bytes which has this content:
  //  MOV  EDI, EDI
  //  PUSH EBP
  //  MOV  EBP, ESP
  // https://www.felixcloutier.com/x86/jmp
  FContAddr := p + sizeof(TJmpCode);
  Buffer.JmpCode := $E9;
  Buffer.JmpOffset := PByte(@HookedGlobalAddAtom) - p - sizeof(TJmpCode);

  // https://devblogs.microsoft.com/oldnewthing/20181206-00/?p=100415
  Windows.WriteProcessMemory(FCurrentProcess, p, @Buffer, sizeof(Buffer), PDWORD(nil)^);
end;


 //=============================================================================
 // Disables interception of GlobalAddAtomW calls.
 //=============================================================================
class procedure TCallHook.UnhookGlobalAddAtom;
begin
  if FBackupBuffer[0] <> 0 then begin
	Windows.WriteProcessMemory(FCurrentProcess, FContAddr - sizeof(TJmpCode), @FBackupBuffer, sizeof(FBackupBuffer), PDWORD(nil)^);
	Windows.FreeLibrary(FhInst);
	FBackupBuffer[0] := 0;
  end;
end;


initialization
  TCallHook.HookGlobalAddAtom;
finalization
  TCallHook.UnhookGlobalAddAtom;

{$ifend}
end.

