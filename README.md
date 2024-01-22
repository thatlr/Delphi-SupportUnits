# Delphi-SupportUnits
Various units for resolving issues or expanding/correcting Delphi functionality.


General note:
I do believe that someone could benefit from the publication of this helper units, but if you have other or better solutions, or don't see
the issues addressed here, please continue to go your own way.


## PrintersEx

This is a thread-safe alternative to Delphi's "Printers" unit.

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

Since it is thread-safe and has no global state (no global TPrinter.PrinterIndex), it can be used by threads/tasks to generate
print jobs, independently and in parallel, even on the same printer.


## ReserveLow2GB

This can be used to test for inappropriate pointer usage, caused by casting a pointer to a (signed) 32bit integer. A pointer above 2GB
has a negative integer value which could result in wrong arithmetics or comparisions.

Including this unit forces all newly allocated memory to appear above the 2 GB virtual address. This applies to:
  - newly allocated heap memory (GetMem, CoTaskMemAlloc, SysAllocString, HeapAlloc, GlobalAlloc, malloc, ...),
  - stack segments of new threads,
  - data segments assigned to new memory mappings,
  - code segements of newly loaded DLLs.

This is not only affecting Delphi code, but *all* other parts of the process also (e.g. memory allocated by Windows components or by
third-party code of any kind).

This unit does not depend on a specific Delphi memory manager and is therefore compatible with everyone.


## MemTest

This unit can be used by Delphi programs to verify correct management of heap memory. From the point of view of the program,
only the speed is adversely affected and more memory is used.

It provides checks for Delphi and COM memory allocations: Detection of double-free and of corruption by writing before the start or
past the end of allocated blocks.
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

Another example:
```
var
  p: PByte;
begin
  p := CoTaskMemAlloc(1);
  p[1] := 0;
  CoTaskMemFree(p);
end.
```

The call to CoTaskMemFree will generate a Debugger break (if running under a debugger) and displays this line in the Event Log window of the IDE:
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


Note on COM memory monitoring:

First observed with Windows 10, the Windows-shipped ADO data driver 'Microsoft.Jet.OLEDB.4.0' seems
to trigger a bug in the Windows COM library "combase.dll". This seems to be related somehow to threads created by this driver: If
you just create an ADO object, and then close the program within a few minutes, you get an Access Violation during ExitProcess,
called by System.pas as the very last step. If you wait long enough, until all threads except the main thread have terminated,
no Access Violation happens. The stack trace of all the involved Windows components seems to indicate that the fault happens as part of the
combase.dll COM sutddown operations, when the IMallocSpy interface was used at some point before. And it happens even when the
IMallocSpy implementation is purely passing through all operations.
As this all is pure Windows functionality, there is no direct way to mitigate it. To prevent this AV from popping up regularly, the MemTest shutdown now calls
TerminateProcess, instead of letting System.pas to continue with ExitProcess. This is the very last operation of the Delphi app anyway,
every execution thereafter is caused by DLL unloading and cleanup, is not controlled by Delphi, and can therefore be skipped safely
in almost all cases.

## WinMemMgr

Simple replacement for the built-in Delphi memory manager, by using the Windows Heap.

(I care for thread-safety and low fragmentation, but not so much for ultimate performance. As the Windows heap is used by most
Visual C/C++ programs through the standard malloc implementation in msvcrt.dll, it should be fine for this requirements.)

It is perhaps worth mentioning that using it with my Tasks demo (see the Delphi-Tasks repository) significantly increases the performance (12.5 to 5.8 seconds, with 24 cores). I wasn't expecting that and it took me a while to find out where the difference comes from. Maybe its due to some alignment or cache-line effects, or maybe the implementation is simply better.


## CorrectLocale

Workaround for a Windows 7 bug. Its usage is mandatory to force SysUtils.InitSysLocale to always get a correct value from
GetThreadLocale() when initializing its regional settings.


## FixAtomLeak

Workaround for the famous RegisterWindowMessage & Atom leak: https://cc.embarcadero.com/Item/28963 The RegisterWindowMessage leak get
fixed in Delphi XE2, but the global atoms will still leak when the program terminates abnormally.
This solution intercepts GlobalAddAtomW() and patches the three Delphi strings passed to this call to contain static content,
thereby fixing the atom leak and also the RegisterWindowMessage leak.


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

For GUI programs in Delphi 2009, "FixAtomLeak" and "VCLFixPack" (https://www.idefixpack.de/blog/bugfix-units/vclfixpack-10/)
are also included, in this order:

```
uses
  WinMemMgr,
  MemTest,
  CorrectLocale,
  FixAtomLeak,
  VCLFixPack,
  Windows,
  ....
```

ReserveLow2GB is only included very seldom during specific testing, since I had very little old code that did pointer arithmetics
by casting to plain "integer". The "PByte" pointer type is much more suitable for this.
