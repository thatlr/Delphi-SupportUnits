# Delphi-SupportUnits
Various units to deal with memory allocation and general issues.


General note:
I do believe that someone could benefit from the publication of this helper units, but if you have other or better solutions, or don't see
the issues addressed here, please continue to go your own way.


## ReserveLow2GB

This can be used to test for inappropriate pointer usage, caused by casting a pointer to a (signed) 32bit integer. Such value
will be negative which could result in wrong arithmetics or comparisions.

Including this unit forces all newly allocated memory to appear above the 2 GB virtual address. This applies to:
  - newly allocated heap memory (GetMem, CoTaskMemAlloc, SysAllocString, HeapAlloc, GlobalAlloc, malloc, ...),
  - stack segments of new threads,
  - data segments assigned to new memory mappings,
  - code segements of newly loaded DLLs.

This is not only affecting Delphi code, but *all* other parts of the process also (e.g. memory allocated by Windows components or by
third-party code of any kind).

This unit does not depend on a specific Delphi memory manager and is therefore compatible with everyone.


## MemTest

This unit can be integrated into Delphi programs to verify correct management of heap memory. From the point of view of the program,
only the speed is adversely affected and more memory is used.

It provides checks for Delphi and COM memory allocations (detection of double-free and of corruption by writing past the end of
allocated blocks).
For Delphi memory, it also detects memory leaks and reports them at program exit.

Example:

```
var
  a: AnsiString;
  u: UnicodeString;
begin
  a := 'a';
  u := 'u';
  pointer(a) := nil;
  pointer(u) := nil;
  TInterfacedObject.Create;
end.
```

will generate this report in the file "memdump_allocated_blocks.txt":

```
*** Delphi Memory: 70 byte in 3 blocks

Addr: 000000008000ed80  Size: 32  Type: TInterfacedObject
  000000008000ed80 50 2a 40 00 00 00 00 00 00 00 00 00 00 00 00 00  P*@.............
  000000008000ed90 38 29 40 00 00 00 00 00 00 00 00 00 00 00 00 00  8)@.............

Addr: 000000008000ed00  Size: 20  Type: UnicodeString
  000000008000ed00 fe fe fe fe b0 04 02 00 01 00 00 00 01 00 00 00  ................
  000000008000ed10 75 00 00 00                                      u...            

Addr: 000000008000ef10  Size: 18  Type: AnsiString
  000000008000ef10 fe fe fe fe e4 04 01 00 01 00 00 00 01 00 00 00  ................
  000000008000ef20 61 00                                            a.              
```

Aother example:
```
var
  p: PByte;
begin
  p := CoTaskMemAlloc(1);
  p[1] := 0;
  CoTaskMemFree(p);
end.
```

The call to CoTaskMemFree will generate a Debugger break (if running under a debugger) and displays this line the Event Log window of the IDE:
```
Debug output: *** COM Memory: Memory corruption detected: p=$000000008000ef60 Prozess Test.exe (7548)
```
and write this to the file "memdump_corrupt_block.txt":
```
Addr=000000008000ef60  Size=49  PreKey=$fefefefefefefefe  PostKey=$efefefefefefef00  PreSize=1  PostSize=1  Prev=0000000000439b40  Next=0000000000439b40  Prev^.Next=000000008000ef60  Next^.Prev=000000008000ef60
  000000008000ef60 40 9b 43 00 00 00 00 00 40 9b 43 00 00 00 00 00  @.C.....@.C.....
  000000008000ef70 01 00 00 00 00 00 00 00 fe fe fe fe fe fe fe fe  ................
  000000008000ef80 fe 00 ef ef ef ef ef ef ef 01 00 00 00 00 00 00  ................
  000000008000ef90 00                                               .               
```
(Note the last two digits of PostKey.)


## WinMemMgr

Simple replacement for the built-in Delphi memory manager, by using the Windows Heap.

(I care for thread-safety and low fragmentation, but not so much for ultimate performance. As the Windows heap is used by most
Visual C/C++ programs through the standard malloc implementation in msvcrt.dll, it should be fine for this requirements.)


## CorrectLocale

Workaround for a Windows 7 bug. Its usage is mandatory to force SysUtils.InitSysLocale to always get a correct value from
GetThreadLocale() when initializing its regional settings.


## Summing it up:

My programs include the following sequence of units in the respective .dpr files:
```
uses
  WinMemMgr,
  MemTest,
  CorrectLocale,
  Windows,
  ....

// IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE = $8000: Terminal server aware
// IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE = $40: Address Space Layout Randomization (ASLR) enabled
// IMAGE_DLLCHARACTERISTICS_NX_COMPAT = $100: Data Execution Prevention (DEP) enabled
{$SetPeOptFlags $8140}
   
// IMAGE_FILE_LARGE_ADDRESS_AWARE: may use heap/code above 2GB
{$SetPeFlags IMAGE_FILE_LARGE_ADDRESS_AWARE}
```

ReserveLow2GB is only included very seldom during specific testing, since I had very little old code that did pointer arithmetics
by casting to plain "integer". The "PByte" pointer type is much more suitable for this.
