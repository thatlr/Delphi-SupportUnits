unit ReserveLow2GB;

{
  *** ONLY FOR TESTING ***

  This can be used to test for inappropriate pointer usage, caused by casting a pointer to a (signed) 32bit integer.
  Such value will be negative which could result in wrong arithmetics or comparisions.

  Including this unit forces all newly allocated memory to appear above the 2 GB virtual address. This applies to:
  - newly allocated heap memory (GetMem, CoTaskMemAlloc, SysAllocString, HeapAlloc, GlobalAlloc, malloc, ...),
  - stack segments of new threads,
  - data segments assigned to new memory mappings,
  - code segements of newly loaded DLLs.
  This is not only affecting Delphi code, but *all* other parts of the process also (e.g. COM-allcated memory, memory
  allocated by Windows components or by third-party DLLs).

  This unit does not depend on a specific Delphi memory manager and is therefore compatible with everyone.

  This unit should be specified as the very first in the uses clause in the project file (.dpr) in order to block the
  entire address range below 2GB.
  For a 32bit program, this assumes that you use ($SetPeFlags IMAGE_FILE_LARGE_ADDRESS_AWARE), otherwise the process
  memory is exhausted right away, resulting in Runtime Error 203.

  Using this memory reservation results in a larger Page Table in the process, but it does not increase the committed
  memory significantly nor does it worsen  the runtime performance.
  There is no point in using it in a 64-bit process, but it is harmless (besides the additional Page Table allocation).

  Use VMMap to monitor the allocations of your process (https://docs.microsoft.com/en-us/sysinternals/downloads/vmmap).
  Please note that you must be familiar with memory management at the operating system level in order to correctly
  interpret the display.
}

{$include LibOptions.inc}

interface

{############################################################################}
implementation
{############################################################################}

uses Windows;

type
  // System.NativeUInt in D2009 is buggy somehow (Internal Error: C12079).
  NativeUInt = type DWORD_PTR;

const
  StepSize = NativeUInt(64 * 1024);		// Windows manages virtual address space with 64k granularity
  Limit2GB = NativeUInt($80000000);


 //===================================================================================================================
 // Enlarges the reservation of the region <Addr> to the maximum possible size.
 //===================================================================================================================
function GrowReservedBlock(Addr: PByte; Size: NativeUInt): PByte;
begin
  // find the longest possible reservation starting from <Addr>:
  repeat
	Assert(Windows.VirtualFree(Addr, 0, MEM_RELEASE));
	inc(Size, StepSize);
  until (NativeUInt(Addr) + Size > Limit2GB) or (Windows.VirtualAlloc(Addr, Size, MEM_RESERVE, PAGE_NOACCESS) = nil);
  // finalize the possible reservation:
  dec(Size, StepSize);
  Assert(Size > 0);
  Result := Windows.VirtualAlloc(Addr, Size, MEM_RESERVE, PAGE_NOACCESS);
  Assert(Result <> nil);
  inc(Result, Size);
end;


 //===================================================================================================================
 // At this point, Windows has already allocated the default heap. First reserve any other address regions below the
 // 2GB limit, and than exhaust the preallocated space in the default-heap.
 //===================================================================================================================
procedure ReserveLowMemory;
var
  Addr: PByte;
  tmp: PByte;
  hHeap: THandle;
begin
  // reserve all free address regions between 64k and 2 GB:
  NativeUInt(Addr) := 64 * 1024;
  repeat
	tmp := Windows.VirtualAlloc(Addr, StepSize, MEM_RESERVE, PAGE_NOACCESS);
	if tmp <> nil then Addr := GrowReservedBlock(tmp, StepSize);
	inc(Addr, StepSize);
  until NativeUInt(Addr) >= Limit2GB;

  // consume all free space in the standard heap for the following allocations to take place above the 2 GB limit:
  hHeap := Windows.GetProcessHeap();
  repeat
	tmp := Windows.HeapAlloc(hHeap, 0, 8);
  until (tmp = nil) or (NativeUInt(tmp) >= Limit2GB);
end;


initialization
  ReserveLowMemory;
end.
