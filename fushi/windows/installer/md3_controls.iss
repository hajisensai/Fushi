// MD3 drawing keeps the existing native button and container HWNDs. Buttons
// still own their caption, default action, tab stop, accelerator, enabled state
// and accessibility tree; surfaces leave their native edit/memo children intact.
// Inno 6.7.3 ships a 32-bit Setup runtime, including on 64-bit Windows. The
// enclosing Md3Chrome version gate limits this implementation to Inno 6.6/6.7.
type
  TMd3NativeInt = Longint;
  TMd3NativeUInt = Longword;

type
  TMd3PaintStruct = record
    DC: THandle;
    Erase: Integer;
    PaintRect: TRect;
    Restore: Integer;
    IncUpdate: Integer;
    Reserved: array[0..31] of Byte;
  end;
  TMd3GdiplusInput = record
    Version: Cardinal;
    DebugCallback: TMd3NativeUInt;
    SuppressBackgroundThread: Integer;
    SuppressExternalCodecs: Integer;
  end;
  TMd3MouseTracking = record
    Size: Cardinal;
    Flags: Cardinal;
    Wnd: THandle;
    HoverTime: Cardinal;
  end;
  TMd3Control = record
    Wnd: THandle;
    Primary: Boolean;
    TextOnly: Boolean;
    Surface: Boolean;
    Radius: Integer;
    Hover: Boolean;
    Tasks: TNewCheckListBox;
  end;

const
  Md3ButtonSubclassId = 6473;
  Md3WmPaint = $000F;
  Md3WmEraseBackground = $0014;
  Md3WmPrintClient = $0318;
  Md3WmNcDestroy = $0082;
  Md3WmMouseMove = $0200;
  Md3WmMouseLeave = $02A3;
  Md3BmGetState = $00F2;
  Md3BstPushed = $0004;

var
  Md3GdiplusToken: TMd3NativeUInt;
  Md3ButtonCallback: TMd3NativeInt;
  Md3Controls: array of TMd3Control;

function Md3SetWindowSubclass(Wnd: THandle; Callback: TMd3NativeInt;
  SubclassId, RefData: TMd3NativeUInt): Integer;
  external 'SetWindowSubclass@comctl32.dll stdcall';
function Md3RemoveWindowSubclass(Wnd: THandle; Callback: TMd3NativeInt;
  SubclassId: TMd3NativeUInt): Integer;
  external 'RemoveWindowSubclass@comctl32.dll stdcall';
function Md3DefSubclassProc(Wnd: THandle; Msg: Cardinal;
  WParam: TMd3NativeUInt; LParam: TMd3NativeInt): TMd3NativeInt;
  external 'DefSubclassProc@comctl32.dll stdcall';
function Md3BeginPaint(Wnd: THandle; var Paint: TMd3PaintStruct): THandle;
  external 'BeginPaint@user32.dll stdcall';
function Md3EndPaint(Wnd: THandle; var Paint: TMd3PaintStruct): Integer;
  external 'EndPaint@user32.dll stdcall';
function Md3GetClientRect(Wnd: THandle; var Bounds: TRect): Integer;
  external 'GetClientRect@user32.dll stdcall';
function Md3IsWindowEnabled(Wnd: THandle): Integer;
  external 'IsWindowEnabled@user32.dll stdcall';
function Md3GetFocus(): THandle;
  external 'GetFocus@user32.dll stdcall';
function Md3GetWindowText(Wnd: THandle; Text: String; MaxCount: Integer): Integer;
  external 'GetWindowTextW@user32.dll stdcall';
function Md3SendMessage(Wnd: THandle; Msg: Cardinal;
  WParam: TMd3NativeUInt; LParam: TMd3NativeInt): TMd3NativeInt;
  external 'SendMessageW@user32.dll stdcall';
function Md3GetListItemRect(Wnd: THandle; Msg: Cardinal;
  Item: Integer; var Bounds: TRect): Integer;
  external 'SendMessageW@user32.dll stdcall';
function Md3TrackMouseEvent(var Tracking: TMd3MouseTracking): Integer;
  external 'TrackMouseEvent@user32.dll stdcall';
function Md3InvalidateRect(Wnd: THandle; Bounds: TMd3NativeUInt;
  Erase: Integer): Integer;
  external 'InvalidateRect@user32.dll stdcall';
function Md3CreateSolidBrush(Color: TColor): THandle;
  external 'CreateSolidBrush@gdi32.dll stdcall';
function Md3DeleteObject(Obj: THandle): Integer;
  external 'DeleteObject@gdi32.dll stdcall';
function Md3FillRect(DC: THandle; var Bounds: TRect; Brush: THandle): Integer;
  external 'FillRect@user32.dll stdcall';
function Md3SaveDC(DC: THandle): Integer;
  external 'SaveDC@gdi32.dll stdcall';
function Md3RestoreDC(DC: THandle; Saved: Integer): Integer;
  external 'RestoreDC@gdi32.dll stdcall';
function Md3SelectObject(DC, Obj: THandle): THandle;
  external 'SelectObject@gdi32.dll stdcall';
function Md3SetBkMode(DC: THandle; Mode: Integer): Integer;
  external 'SetBkMode@gdi32.dll stdcall';
function Md3SetTextColor(DC: THandle; Color: TColor): TColor;
  external 'SetTextColor@gdi32.dll stdcall';
function Md3DrawText(DC: THandle; Text: String; Count: Integer;
  var Bounds: TRect; Format: Cardinal): Integer;
  external 'DrawTextW@user32.dll stdcall';
function Md3GdiplusStartup(var Token: TMd3NativeUInt;
  var Input: TMd3GdiplusInput; Output: TMd3NativeUInt): Integer;
  external 'GdiplusStartup@gdiplus.dll stdcall';
procedure Md3GdiplusShutdown(Token: TMd3NativeUInt);
  external 'GdiplusShutdown@gdiplus.dll stdcall';
function Md3CreateGraphics(DC: THandle; var Graphics: TMd3NativeUInt): Integer;
  external 'GdipCreateFromHDC@gdiplus.dll stdcall';
function Md3DeleteGraphics(Graphics: TMd3NativeUInt): Integer;
  external 'GdipDeleteGraphics@gdiplus.dll stdcall';
function Md3SetSmoothingMode(Graphics: TMd3NativeUInt; Mode: Integer): Integer;
  external 'GdipSetSmoothingMode@gdiplus.dll stdcall';
function Md3CreatePath(FillMode: Integer; var Path: TMd3NativeUInt): Integer;
  external 'GdipCreatePath@gdiplus.dll stdcall';
function Md3AddPathArc(Path: TMd3NativeUInt; X, Y, Width, Height: Integer;
  StartAngle, SweepAngle: Single): Integer;
  external 'GdipAddPathArcI@gdiplus.dll stdcall';
function Md3ClosePath(Path: TMd3NativeUInt): Integer;
  external 'GdipClosePathFigure@gdiplus.dll stdcall';
function Md3AddPathLine(Path: TMd3NativeUInt; X1, Y1, X2, Y2: Integer): Integer;
  external 'GdipAddPathLineI@gdiplus.dll stdcall';
function Md3DeletePath(Path: TMd3NativeUInt): Integer;
  external 'GdipDeletePath@gdiplus.dll stdcall';
function Md3CreateGdiBrush(Color: Cardinal; var Brush: TMd3NativeUInt): Integer;
  external 'GdipCreateSolidFill@gdiplus.dll stdcall';
function Md3DeleteGdiBrush(Brush: TMd3NativeUInt): Integer;
  external 'GdipDeleteBrush@gdiplus.dll stdcall';
function Md3FillPath(Graphics, Brush, Path: TMd3NativeUInt): Integer;
  external 'GdipFillPath@gdiplus.dll stdcall';
function Md3CreatePen(Color: Cardinal; Width: Single; UnitType: Integer;
  var Pen: TMd3NativeUInt): Integer;
  external 'GdipCreatePen1@gdiplus.dll stdcall';
function Md3DeletePen(Pen: TMd3NativeUInt): Integer;
  external 'GdipDeletePen@gdiplus.dll stdcall';
function Md3DrawPath(Graphics, Pen, Path: TMd3NativeUInt): Integer;
  external 'GdipDrawPath@gdiplus.dll stdcall';

function Md3Argb(Color: TColor): Cardinal;
begin
  // TColor is COLORREF (BGR); GDI+ expects opaque ARGB.
  Result := $FF000000 or ((Color and $FF) shl 16) or
    (Color and $FF00) or ((Color shr 16) and $FF);
end;

function Md3Blend(Base, Overlay: TColor; Percent: Integer): TColor;
var
  R, G, B: Integer;
begin
  R := ((Base and $FF) * (100 - Percent) + (Overlay and $FF) * Percent) div 100;
  G := (((Base shr 8) and $FF) * (100 - Percent) +
    ((Overlay shr 8) and $FF) * Percent) div 100;
  B := (((Base shr 16) and $FF) * (100 - Percent) +
    ((Overlay shr 16) and $FF) * Percent) div 100;
  Result := R or (G shl 8) or (B shl 16);
end;

function Md3OnPrimary(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#381E72')
  else
    Result := StrToColor('#FFFFFF');
end;

function Md3PrimaryContainer(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#4F378B')
  else
    Result := StrToColor('#EADDFF');
end;

function Md3OnPrimaryContainer(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#EADDFF')
  else
    Result := StrToColor('#21005D');
end;

function Md3PillPath(const Bounds: TRect; Inset: Integer): TMd3NativeUInt;
var
  X, Y, W, H: Integer;
begin
  Result := 0;
  X := Bounds.Left + Inset;
  Y := Bounds.Top + Inset;
  W := Bounds.Right - Bounds.Left - 2 * Inset;
  H := Bounds.Bottom - Bounds.Top - 2 * Inset;
  if (W <= 0) or (H <= 0) then
    Exit;
  if Md3CreatePath(0, Result) <> 0 then
    Exit;
  Md3AddPathArc(Result, X, Y, H, H, 90, 180);
  Md3AddPathArc(Result, X + W - H, Y, H, H, 270, 180);
  Md3ClosePath(Result);
end;

function Md3RoundRectPath(const Bounds: TRect; Radius: Integer): TMd3NativeUInt;
var
  X, Y, W, H, Diameter: Integer;
begin
  Result := 0;
  X := Bounds.Left;
  Y := Bounds.Top;
  W := Bounds.Right - Bounds.Left;
  H := Bounds.Bottom - Bounds.Top;
  Diameter := Radius * 2;
  if Diameter > W then Diameter := W;
  if Diameter > H then Diameter := H;
  if (W <= 0) or (H <= 0) or (Diameter <= 0) then
    Exit;
  if Md3CreatePath(0, Result) <> 0 then
    Exit;
  Md3AddPathArc(Result, X, Y, Diameter, Diameter, 180, 90);
  Md3AddPathArc(Result, X + W - Diameter, Y, Diameter, Diameter, 270, 90);
  Md3AddPathArc(Result, X + W - Diameter, Y + H - Diameter, Diameter, Diameter, 0, 90);
  Md3AddPathArc(Result, X, Y + H - Diameter, Diameter, Diameter, 90, 90);
  Md3ClosePath(Result);
end;

procedure Md3PaintSurface(Index: Integer; DC: THandle);
var
  Bounds: TRect;
  Brush: THandle;
  Graphics, Path, Fill: TMd3NativeUInt;
  SavedDC: Integer;
begin
  Md3GetClientRect(Md3Controls[Index].Wnd, Bounds);
  SavedDC := Md3SaveDC(DC);
  try
    Brush := Md3CreateSolidBrush(Md3Surface);
    Md3FillRect(DC, Bounds, Brush);
    Md3DeleteObject(Brush);
    Graphics := 0;
    if Md3CreateGraphics(DC, Graphics) = 0 then
    begin
      try
        Md3SetSmoothingMode(Graphics, 4);
        Path := Md3RoundRectPath(Bounds, ScaleY(Md3Controls[Index].Radius));
        if Path <> 0 then
        begin
          Fill := 0;
          if Md3CreateGdiBrush(Md3Argb(Md3SurfaceContainer), Fill) = 0 then
          begin
            Md3FillPath(Graphics, Fill, Path);
            Md3DeleteGdiBrush(Fill);
          end;
          Md3DeletePath(Path);
        end;
      finally
        Md3DeleteGraphics(Graphics);
      end;
    end;
  finally
    Md3RestoreDC(DC, SavedDC);
  end;
end;

procedure Md3DrawCheck(Graphics: TMd3NativeUInt; Bounds: TRect;
  State: TCheckBoxState; Enabled: Boolean);
var
  Path, Fill, Pen, Mark: TMd3NativeUInt;
  Color, MarkColor: TColor;
  W, H: Integer;
begin
  Color := Md3Primary;
  MarkColor := Md3OnPrimary;
  if not Enabled then
  begin
    Color := Md3Blend(Md3Surface, Md3OnSurface, 38);
    MarkColor := Md3Surface;
  end;
  Path := Md3RoundRectPath(Bounds, ScaleY(2));
  if Path = 0 then Exit;
  try
    if State <> cbUnchecked then
    begin
      Fill := 0;
      if Md3CreateGdiBrush(Md3Argb(Color), Fill) = 0 then
      begin
        Md3FillPath(Graphics, Fill, Path);
        Md3DeleteGdiBrush(Fill);
      end;
      Mark := 0;
      if Md3CreatePath(0, Mark) = 0 then
      begin
        W := Bounds.Right - Bounds.Left;
        H := Bounds.Bottom - Bounds.Top;
        if State = cbGrayed then
          Md3AddPathLine(Mark, Bounds.Left + W div 4, Bounds.Top + H div 2,
            Bounds.Right - W div 4, Bounds.Top + H div 2)
        else
        begin
          Md3AddPathLine(Mark, Bounds.Left + W div 5, Bounds.Top + H div 2,
            Bounds.Left + W * 2 div 5, Bounds.Top + H * 7 div 10);
          Md3AddPathLine(Mark, Bounds.Left + W * 2 div 5, Bounds.Top + H * 7 div 10,
            Bounds.Left + W * 4 div 5, Bounds.Top + H * 3 div 10);
        end;
        Pen := 0;
        if Md3CreatePen(Md3Argb(MarkColor), ScaleY(2), 2, Pen) = 0 then
        begin
          Md3DrawPath(Graphics, Pen, Mark);
          Md3DeletePen(Pen);
        end;
        Md3DeletePath(Mark);
      end;
    end
    else
    begin
      if Enabled then Color := Md3Blend(Md3Surface, Md3OnSurface, 70);
      Pen := 0;
      if Md3CreatePen(Md3Argb(Color), ScaleY(2), 2, Pen) = 0 then
      begin
        Md3DrawPath(Graphics, Pen, Path);
        Md3DeletePen(Pen);
      end;
    end;
  finally
    Md3DeletePath(Path);
  end;
end;

procedure Md3PaintTasks(Index: Integer; DC: THandle);
var
  List: TNewCheckListBox;
  Bounds, Row, Check, TextBounds, MeasureBounds: TRect;
  Brush: THandle;
  Graphics, Path, Fill: TMd3NativeUInt;
  SavedDC, Item, BoxSize, Padding, Flags, TextHeight: Integer;
  IsGroup, Enabled, Focused: Boolean;
  Caption: String;
  TextColor: TColor;
  RowFont: TFont;
begin
  List := Md3Controls[Index].Tasks;
  Md3GetClientRect(Md3Controls[Index].Wnd, Bounds);
  SavedDC := Md3SaveDC(DC);
  RowFont := TFont.Create;
  try
    Brush := Md3CreateSolidBrush(Md3Surface);
    Md3FillRect(DC, Bounds, Brush);
    Md3DeleteObject(Brush);
    Graphics := 0;
    try
      Padding := ScaleX(12);
      BoxSize := ScaleY(18);
      for Item := 0 to List.Items.Count - 1 do
      begin
        // Use the real variable-height native row; no parallel hit-test grid.
        if Md3GetListItemRect(List.Handle, $0198, Item, Row) = -1 then Continue;
        if (Row.Bottom <= Bounds.Top) or (Row.Top >= Bounds.Bottom) then Continue;
        if Md3CreateGraphics(DC, Graphics) <> 0 then Exit;
        Md3SetSmoothingMode(Graphics, 4);
        // TWizardForm populates group rows with nil, and task rows with the
        // task entry object. The native list retains all toggle/group behavior.
        IsGroup := List.ItemObject[Item] = nil;
        Enabled := List.Enabled and List.ItemEnabled[Item];
        Focused := (Md3GetFocus() = List.Handle) and (List.ItemIndex = Item) and
          (not IsGroup) and Enabled;
        if Focused then
        begin
          Path := Md3RoundRectPath(Row, ScaleY(8));
          if Path <> 0 then
          begin
            Fill := 0;
            if Md3CreateGdiBrush(Md3Argb(Md3Blend(Md3Surface, Md3Primary, 10)), Fill) = 0 then
            begin
              Md3FillPath(Graphics, Fill, Path);
              Md3DeleteGdiBrush(Fill);
            end;
            Md3DeletePath(Path);
          end;
        end;
        TextBounds := Row;
        TextBounds.Left := Row.Left + Padding + List.ItemLevel[Item] * (BoxSize + Padding);
        TextBounds.Right := Row.Right - Padding;
        if not IsGroup then
        begin
          Check.Left := TextBounds.Left;
          Check.Top := Row.Top + (Row.Bottom - Row.Top - BoxSize) div 2;
          Check.Right := Check.Left + BoxSize;
          Check.Bottom := Check.Top + BoxSize;
          Md3DrawCheck(Graphics, Check, List.State[Item], Enabled);
          TextBounds.Left := Check.Right + Padding;
        end;
        // Release Graphics before drawing GDI text on the same device context.
        Md3DeleteGraphics(Graphics);
        Graphics := 0;
        Md3SelectObject(DC, Md3SendMessage(List.Handle, $0031, 0, 0));
        RowFont.Assign(List.Font);
        RowFont.Style := List.ItemFontStyle[Item];
        Md3SelectObject(DC, RowFont.Handle);
        TextColor := Md3OnSurface;
        if IsGroup then TextColor := Md3Blend(Md3Surface, Md3OnSurface, 76)
        else if not Enabled then TextColor := Md3Blend(Md3Surface, Md3OnSurface, 38);
        Md3SetTextColor(DC, TextColor);
        Md3SetBkMode(DC, 1);
        Caption := List.ItemCaption[Item];
        Flags := $0010; // DT_WORDBREAK, matching native variable-height items.
        if IsGroup or not List.WantTabs then Flags := Flags or $0800 // NOPREFIX
        else if (Md3SendMessage(List.Handle, $0129, 0, 0) and $0002) <> 0 then
          Flags := Flags or $00100000;
        MeasureBounds := TextBounds;
        TextHeight := Md3DrawText(DC, Caption, Length(Caption), MeasureBounds, Flags or $0400);
        if TextHeight < Row.Bottom - Row.Top then
          TextBounds.Top := Row.Top + (Row.Bottom - Row.Top - TextHeight) div 2;
        Md3DrawText(DC, Caption, Length(Caption), TextBounds, Flags);
      end;
    finally
      if Graphics <> 0 then Md3DeleteGraphics(Graphics);
    end;
  finally
    Md3RestoreDC(DC, SavedDC);
    RowFont.Free;
  end;
end;

function Md3CaptionWithoutHiddenAccelerator(const Caption: String): String;
var
  I: Integer;
  Letter: String;
begin
  Result := Caption;
  I := Length(Result) - 3;
  while I > 0 do
  begin
    if (Copy(Result, I, 2) = '(&') and (Copy(Result, I + 3, 1) = ')') then
    begin
      Letter := Uppercase(Copy(Result, I + 2, 1));
      if (Letter >= 'A') and (Letter <= 'Z') then
        Delete(Result, I, 4);
    end;
    I := I - 1;
  end;
end;

procedure Md3PaintButton(Index: Integer; DC: THandle);
var
  Wnd, Brush: THandle;
  Bounds, TextBounds: TRect;
  Graphics, Path, Fill, Pen, FocusPath: TMd3NativeUInt;
  FillColor, TextColor: TColor;
  Caption: String;
  Enabled, Focused, Pressed: Boolean;
  SavedDC, CaptionLength, TextFlags: Integer;
begin
  Wnd := Md3Controls[Index].Wnd;
  Md3GetClientRect(Wnd, Bounds);
  Enabled := Md3IsWindowEnabled(Wnd) <> 0;
  Focused := (Md3GetFocus() = Wnd) and Enabled;
  Pressed := (Md3SendMessage(Wnd, Md3BmGetState, 0, 0) and Md3BstPushed) <> 0;
  if Md3Controls[Index].TextOnly then
  begin
    FillColor := Md3Surface;
    TextColor := Md3Primary;
  end
  else if Md3Controls[Index].Primary then
  begin
    FillColor := Md3Primary;
    TextColor := Md3OnPrimary;
  end
  else
  begin
    FillColor := Md3PrimaryContainer;
    TextColor := Md3OnPrimaryContainer;
  end;
  if not Enabled then
  begin
    if Md3Controls[Index].TextOnly then
      FillColor := Md3Surface
    else
      FillColor := Md3Blend(Md3Surface, Md3OnSurface, 12);
    TextColor := Md3Blend(Md3Surface, Md3OnSurface, 38);
  end
  else if Pressed then
    FillColor := Md3Blend(FillColor, TextColor, 12)
  else if Focused then
    FillColor := Md3Blend(FillColor, TextColor, 8)
  else if Md3Controls[Index].Hover then
    FillColor := Md3Blend(FillColor, TextColor, 8);

  SavedDC := Md3SaveDC(DC);
  try
    Brush := Md3CreateSolidBrush(Md3Surface);
    Md3FillRect(DC, Bounds, Brush);
    Md3DeleteObject(Brush);
    Graphics := 0;
    if Md3CreateGraphics(DC, Graphics) = 0 then
    begin
      try
        Md3SetSmoothingMode(Graphics, 4); // AntiAlias: no binary window-region edge.
        Path := Md3PillPath(Bounds, ScaleY(1));
        if Path <> 0 then
        begin
          Fill := 0;
          if Md3CreateGdiBrush(Md3Argb(FillColor), Fill) = 0 then
          begin
            Md3FillPath(Graphics, Fill, Path);
            Md3DeleteGdiBrush(Fill);
          end;
          Md3DeletePath(Path);
        end;
        if Focused then
        begin
          FocusPath := Md3PillPath(Bounds, ScaleY(1));
          if FocusPath <> 0 then
          begin
            Pen := 0;
            if Md3CreatePen(Md3Argb(Md3Primary), ScaleY(1), 2, Pen) = 0 then
            begin
              Md3DrawPath(Graphics, Pen, FocusPath);
              Md3DeletePen(Pen);
            end;
            Md3DeletePath(FocusPath);
          end;
        end;
      finally
        Md3DeleteGraphics(Graphics);
      end;
    end;
    // Fetch live native text/font each paint: Inno changes Next to Install/Finish.
    CaptionLength := Md3SendMessage(Wnd, $000E, 0, 0); // WM_GETTEXTLENGTH
    Caption := StringOfChar(#0, CaptionLength + 1);
    CaptionLength := Md3GetWindowText(Wnd, Caption, Length(Caption));
    SetLength(Caption, CaptionLength);
    Md3SelectObject(DC, Md3SendMessage(Wnd, $0031, 0, 0)); // WM_GETFONT
    Md3SetTextColor(DC, TextColor);
    Md3SetBkMode(DC, 1); // TRANSPARENT
    TextBounds := Bounds;
    TextBounds.Left := TextBounds.Left + ScaleX(12);
    TextBounds.Right := TextBounds.Right - ScaleX(12);
    TextFlags := $0001 or $0004 or $0020; // CENTER | VCENTER | SINGLELINE
    if (Md3SendMessage(Wnd, $0129, 0, 0) and $0002) <> 0 then
    begin
      TextFlags := TextFlags or $00100000; // WM_QUERYUISTATE / DT_HIDEPREFIX
      // Keep the native caption and accelerator intact. Only the visual copy
      // hides Chinese "(&N)" suffixes while Windows hides keyboard cues.
      Caption := Md3CaptionWithoutHiddenAccelerator(Caption);
    end;
    Md3DrawText(DC, Caption, Length(Caption), TextBounds, TextFlags);
  finally
    Md3RestoreDC(DC, SavedDC);
  end;
end;

function Md3ButtonWindowProc(Wnd: THandle; Msg: Cardinal;
  WParam: TMd3NativeUInt; LParam: TMd3NativeInt;
  SubclassId, RefData: TMd3NativeUInt): TMd3NativeInt;
var
  Index: Integer;
  DC: THandle;
  Paint: TMd3PaintStruct;
  Tracking: TMd3MouseTracking;
begin
  Index := RefData - 1;
  if (Index < 0) or (Index >= GetArrayLength(Md3Controls)) then
  begin
    Result := Md3DefSubclassProc(Wnd, Msg, WParam, LParam);
    Exit;
  end;
  if Msg = Md3WmNcDestroy then
  begin
    Md3RemoveWindowSubclass(Wnd, Md3ButtonCallback, SubclassId);
    Md3Controls[Index].Wnd := 0;
    Result := Md3DefSubclassProc(Wnd, Msg, WParam, LParam);
    Exit;
  end;
  if (Msg = Md3WmPaint) and (Md3GdiplusToken <> 0) then
  begin
    DC := Md3BeginPaint(Wnd, Paint);
    try
      if DC <> 0 then
      begin
        if Md3Controls[Index].Surface then
          Md3PaintSurface(Index, DC)
        else if Md3Controls[Index].Tasks <> nil then
          Md3PaintTasks(Index, DC)
        else
          Md3PaintButton(Index, DC);
      end;
    finally
      Md3EndPaint(Wnd, Paint);
    end;
    Result := 0;
    Exit;
  end;
  if (Msg = Md3WmPrintClient) and (Md3GdiplusToken <> 0) then
  begin
    if WParam <> 0 then
    begin
      if Md3Controls[Index].Surface then
        Md3PaintSurface(Index, WParam)
      else if Md3Controls[Index].Tasks <> nil then
        Md3PaintTasks(Index, WParam)
      else
        Md3PaintButton(Index, WParam);
    end;
    Result := 0;
    Exit;
  end;
  if Msg = Md3WmEraseBackground then
  begin
    Result := 1;
    Exit;
  end;
  // A surface is a native parent, not an interactive replacement for its child
  // edit/memo. Forward every input, focus, and child-notification message.
  if Md3Controls[Index].Surface then
  begin
    Result := Md3DefSubclassProc(Wnd, Msg, WParam, LParam);
    Exit;
  end;
  if (Msg = Md3WmMouseMove) and not Md3Controls[Index].Hover then
  begin
    Md3Controls[Index].Hover := True;
    Tracking.Size := SizeOf(Tracking);
    Tracking.Flags := $0002; // TME_LEAVE
    Tracking.Wnd := Wnd;
    Tracking.HoverTime := 0;
    Md3TrackMouseEvent(Tracking);
    Md3InvalidateRect(Wnd, 0, 0);
  end
  else if Msg = Md3WmMouseLeave then
  begin
    Md3Controls[Index].Hover := False;
    Md3InvalidateRect(Wnd, 0, 0);
  end;

  // Input, dialog, accessibility and native state messages always continue.
  Result := Md3DefSubclassProc(Wnd, Msg, WParam, LParam);
  // Native buttons may redraw directly while changing state; schedule our paint
  // after that work. Do not dispatch a second click or alter any button style bit.
  if (Msg = $0007) or (Msg = $0008) or (Msg = $000A) or
    (Msg = $000C) or (Msg = $0030) or (Msg = $00F3) or (Msg = $00F4) or
    (Msg = $0100) or (Msg = $0101) or (Msg = $0128) or
    (Msg = $0201) or (Msg = $0202) or (Msg = $0215) or
    (Msg = $0115) or (Msg = $020A) then
    Md3InvalidateRect(Wnd, 0, 0);
end;

procedure Md3InitializeControls();
var
  Input: TMd3GdiplusInput;
begin
  if Md3GdiplusToken <> 0 then
    Exit;
  Input.Version := 1;
  Input.DebugCallback := 0;
  Input.SuppressBackgroundThread := 0;
  Input.SuppressExternalCodecs := 0;
  if Md3GdiplusStartup(Md3GdiplusToken, Input, 0) <> 0 then
  begin
    Md3GdiplusToken := 0;
    Log('MD3: GDI+ initialization failed; keeping native buttons.');
    Exit;
  end;
  Md3ButtonCallback := CreateCallback(@Md3ButtonWindowProc);
end;

procedure Md3PrepareButton(Btn: TNewButton);
begin
  Md3InitializeControls();
  if Md3GdiplusToken = 0 then
    Exit;
  // Prepare a custom page's buttons after Add, before that page is activated.
  // Changing VCL StyleElements while it is showing can defer HWND recreation
  // until the page-change callback returns and thereby remove a new subclass.
  // These property setters do not request the hidden button's Handle.
  Btn.Font.Name := Md3UiFontName(Btn.Font.Name);
  Btn.Font.Size := 9;
  Btn.Height := ScaleY(32);
  Btn.StyleElements := [];
end;

procedure Md3StyleButton(Btn: TNewButton; Primary: Boolean);
var
  Index: Integer;
begin
  Md3InitializeControls();
  if Md3GdiplusToken = 0 then
    Exit;
  Md3PrepareButton(Btn);
  for Index := 0 to GetArrayLength(Md3Controls) - 1 do
  begin
    if Md3Controls[Index].Wnd = Btn.Handle then
    begin
      Md3Controls[Index].Primary := Primary;
      Md3Controls[Index].TextOnly := Btn = WizardForm.CancelButton;
      Md3InvalidateRect(Btn.Handle, 0, 0);
      Exit;
    end;
  end;
  Index := GetArrayLength(Md3Controls);
  SetArrayLength(Md3Controls, Index + 1);
  Md3Controls[Index].Wnd := Btn.Handle;
  Md3Controls[Index].Primary := Primary;
  Md3Controls[Index].TextOnly := Btn = WizardForm.CancelButton;
  Md3Controls[Index].Surface := False;
  Md3Controls[Index].Hover := False;
  if Md3SetWindowSubclass(Btn.Handle, Md3ButtonCallback,
    Md3ButtonSubclassId, Index + 1) = 0 then
  begin
    Md3Controls[Index].Wnd := 0;
    Btn.StyleElements := [seFont, seClient, seBorder];
    Log('MD3: button subclass failed; keeping the native style.');
  end;
  Md3InvalidateRect(Btn.Handle, 0, 0);
end;

procedure Md3StyleSurface(Panel: TPanel; Radius: Integer);
var
  Index: Integer;
begin
  Md3InitializeControls();
  if Md3GdiplusToken = 0 then
    Exit;
  // Configure these properties while constructing the panel. Call this method
  // for a visible page, after its native hierarchy has been created.
  for Index := 0 to GetArrayLength(Md3Controls) - 1 do
  begin
    if Md3Controls[Index].Wnd = Panel.Handle then
    begin
      Md3Controls[Index].Radius := Radius;
      Md3InvalidateRect(Panel.Handle, 0, 0);
      Exit;
    end;
  end;
  Index := GetArrayLength(Md3Controls);
  SetArrayLength(Md3Controls, Index + 1);
  Md3Controls[Index].Wnd := Panel.Handle;
  Md3Controls[Index].Surface := True;
  Md3Controls[Index].Radius := Radius;
  if Md3SetWindowSubclass(Panel.Handle, Md3ButtonCallback,
    Md3ButtonSubclassId, Index + 1) = 0 then
  begin
    Md3Controls[Index].Wnd := 0;
    Log('MD3: surface subclass failed; keeping the native panel.');
  end;
  Md3InvalidateRect(Panel.Handle, 0, 0);
end;

procedure Md3PrepareTasks(List: TNewCheckListBox);
begin
  Md3InitializeControls();
  if Md3GdiplusToken = 0 then Exit;
  List.StyleElements := [];
  List.Font.Name := Md3UiFontName(List.Font.Name);
  List.Font.Size := 10;
  List.Color := Md3Surface;
end;

procedure Md3StyleTasks(List: TNewCheckListBox);
var
  Index: Integer;
begin
  Md3InitializeControls();
  if Md3GdiplusToken = 0 then Exit;
  // PrepareTasks runs while constructing the wizard, before this page shows.
  // This method only attaches paint to the current native HWND.
  for Index := 0 to GetArrayLength(Md3Controls) - 1 do
    if Md3Controls[Index].Wnd = List.Handle then
    begin
      Md3InvalidateRect(List.Handle, 0, 0);
      Exit;
    end;
  Index := GetArrayLength(Md3Controls);
  SetArrayLength(Md3Controls, Index + 1);
  Md3Controls[Index].Wnd := List.Handle;
  Md3Controls[Index].Tasks := List;
  if Md3SetWindowSubclass(List.Handle, Md3ButtonCallback,
    Md3ButtonSubclassId, Index + 1) = 0 then
  begin
    Md3Controls[Index].Wnd := 0;
    Log('MD3: tasks subclass failed; keeping the native task list.');
  end;
  Md3InvalidateRect(List.Handle, 0, 0);
end;

procedure Md3FinalizeControls();
var
  Index: Integer;
begin
  for Index := 0 to GetArrayLength(Md3Controls) - 1 do
  begin
    if Md3Controls[Index].Wnd <> 0 then
      Md3RemoveWindowSubclass(Md3Controls[Index].Wnd,
        Md3ButtonCallback, Md3ButtonSubclassId);
  end;
  SetArrayLength(Md3Controls, 0);
  if Md3GdiplusToken <> 0 then
  begin
    Md3GdiplusShutdown(Md3GdiplusToken);
    Md3GdiplusToken := 0;
  end;
end;
