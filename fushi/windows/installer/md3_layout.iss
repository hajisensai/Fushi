{ The wizard remains Inno's native page flow. Layout and drawing never replace
  NextButtonClick, path edits, task selection, or the installation summary. }
var
  Md3StepLabel: TNewStaticText;
  Md3SummaryCard: TPanel;

function Md3OnSurfaceVariant(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#CAC4D0')
  else
    Result := StrToColor('#49454F');
end;

procedure Md3Text(LabelControl: TNewStaticText; Size: Integer; Muted: Boolean);
begin
  LabelControl.StyleElements := LabelControl.StyleElements - [seFont];
  LabelControl.Font.Name := Md3UiFontName(LabelControl.Font.Name);
  LabelControl.Font.Size := Size;
  LabelControl.Font.Style := [];
  if Muted then
    LabelControl.Font.Color := Md3OnSurfaceVariant
  else
    LabelControl.Font.Color := Md3OnSurface;
end;

{ 按钮宽度按**当前语言**的文字量出来，不写死：德语「Durchsuchen…」「Abbrechen」
  在固定 84/64 px 里会被裁掉（#2716）。量字用与按钮相同的字体与字号（见
  Md3PrepareButton），只建一个不可见的测量标签，不触碰任何按钮的 Handle。
  MinWidth 保住中英文原来的视觉宽度。 }
function Md3ButtonWidth(const Captions: array of String; MinWidth: Integer): Integer;
var
  Probe: TNewStaticText;
  Index, Needed: Integer;
begin
  Result := MinWidth;
  Probe := TNewStaticText.Create(WizardForm);
  try
    Probe.Visible := False;
    Probe.AutoSize := True;
    Probe.WordWrap := False;
    Probe.Font.Name := Md3UiFontName(WizardForm.Font.Name);
    Probe.Font.Size := 9;
    Probe.Parent := WizardForm;
    for Index := 0 to GetArrayLength(Captions) - 1 do
    begin
      Probe.Caption := Captions[Index];
      Needed := Probe.Width + ScaleX(32);
      if Needed > Result then
        Result := Needed;
    end;
  finally
    Probe.Free;
  end;
end;

{ Keep the native path editor, including autocomplete, selection and validation.
  The container adds padding without clipping the editor's selection or glyphs.
  Do not request any Handle here: hidden notebook pages must stay uncreated. }
procedure Md3PathField(Edit: TEdit; Browse: TNewButton;
  Prompt: TNewStaticText; Top: Integer);
var
  Container: TPanel;
  FieldLabel: TNewStaticText;
  SavedText: String;
  Order: Integer;
begin
  SavedText := Edit.Text;
  Order := Edit.TabOrder;
  Container := TPanel.Create(WizardForm);
  Container.Parent := Edit.Parent;
  Container.StyleElements := [];
  Container.ParentBackground := False;
  Container.BevelOuter := bvNone;
  Container.Color := Md3SurfaceContainer;
  Browse.Width := Md3ButtonWidth([Browse.Caption], ScaleX(84));
  Container.SetBounds(0, Top,
    WizardForm.InnerNotebook.Width - Browse.Width - ScaleX(12), ScaleY(56));
  Container.TabOrder := Order;
  Container.TabStop := False;

  FieldLabel := TNewStaticText.Create(WizardForm);
  FieldLabel.Parent := Container;
  FieldLabel.Caption := Prompt.Caption;
  FieldLabel.SetBounds(ScaleX(16), ScaleY(8), Container.Width - ScaleX(32), ScaleY(18));
  Md3Text(FieldLabel, 9, True);
  FieldLabel.FocusControl := Edit;
  FieldLabel.TabOrder := 0;
  Prompt.Visible := False;

  Edit.Parent := Container;
  Edit.StyleElements := [];
  Edit.BorderStyle := bsNone;
  Edit.AutoSize := False;
  Edit.Color := Md3SurfaceContainer;
  Edit.Font.Name := Md3UiFontName(Edit.Font.Name);
  Edit.Font.Color := Md3OnSurface;
  Edit.Font.Size := 10;
  Edit.SetBounds(ScaleX(16), ScaleY(27), Container.Width - ScaleX(32), ScaleY(22));
  Edit.TabOrder := 1;
  Edit.Text := SavedText;

  Browse.SetBounds(Container.Width + ScaleX(12), Top + ScaleY(12),
    Browse.Width, ScaleY(32));
  Md3PrepareButton(Browse);
end;

procedure Md3LayoutDataRootPage();
begin
  DataRootPage.Surface.StyleElements := [];
  DataRootPage.Surface.Color := Md3Surface;
  Md3Text(DataRootPage.SubCaptionLabel, 10, True);
  DataRootPage.SubCaptionLabel.SetBounds(0, 0, DataRootPage.SurfaceWidth, ScaleY(60));
  DataRootPage.PromptLabels[0].Caption := CustomMessage('FushiDataRootLabel');
  Md3PathField(DataRootPage.Edits[0], DataRootPage.Buttons[0],
    DataRootPage.PromptLabels[0], ScaleY(84));
end;

procedure Md3FitPathField(Edit: TEdit; Browse: TNewButton);
var
  Container: TWinControl;
  RowWidth: Integer;
begin
  { Notebook pages acquire their final client width when activated. Fit both
    native fields from that page, not from its earlier construction bounds. }
  Container := Edit.Parent;
  RowWidth := Container.Parent.ClientWidth;
  Container.Width := RowWidth - Browse.Width - ScaleX(12);
  Edit.Width := Container.Width - ScaleX(32);
  { RTL 语言（arabic）下 Inno 只在窗体 Show 时把控件坐标镜像一次；这里在 Show
    之后重排，坐标必须自己镜像，否则「浏览」按钮按 LTR 坐标落到窗口外（#2716）。
    ControlsFlipped 只在镜像已经发生后为真；尚未 Show 时给 LTR 坐标，交给 Inno 翻。 }
  if WizardForm.ControlsFlipped then
  begin
    Container.Left := RowWidth - Container.Width;
    Browse.Left := Container.Left - ScaleX(12) - Browse.Width;
  end
  else
  begin
    Container.Left := 0;
    Browse.Left := Container.Width + ScaleX(12);
  end;
  Md3StyleSurface(TPanel(Edit.Parent), 10);
end;

procedure ApplyMd3Chrome();
var
  BodyWidth, FooterTop, PageIndex, NextWidth, BackWidth: Integer;
begin
  WizardForm.ClientWidth := ScaleX(592);
  WizardForm.ClientHeight := ScaleY(440);
  WizardForm.StyleElements := WizardForm.StyleElements - [seClient];
  WizardForm.Color := Md3Surface;
  FooterTop := WizardForm.ClientHeight - ScaleY(76);
  BodyWidth := WizardForm.ClientWidth - ScaleX(64);
  WizardForm.OuterNotebook.Height := FooterTop;
  WizardForm.MainPanel.StyleElements := [];
  WizardForm.MainPanel.Color := Md3Surface;
  WizardForm.MainPanel.Height := ScaleY(112);
  WizardForm.InnerPage.StyleElements := [];
  WizardForm.InnerPage.Color := Md3Surface;
  for PageIndex := 0 to WizardForm.InnerNotebook.PageCount - 1 do
  begin
    WizardForm.InnerNotebook.Pages[PageIndex].StyleElements := [];
    WizardForm.InnerNotebook.Pages[PageIndex].Color := Md3Surface;
  end;
  WizardForm.InnerNotebook.SetBounds(ScaleX(32), ScaleY(126),
    BodyWidth, FooterTop - ScaleY(138));

  Md3StepLabel := TNewStaticText.Create(WizardForm);
  Md3StepLabel.Parent := WizardForm.MainPanel;
  Md3StepLabel.SetBounds(ScaleX(32), ScaleY(20), BodyWidth - ScaleX(64), ScaleY(18));
  Md3Text(Md3StepLabel, 9, True);
  Md3StepLabel.Font.Color := Md3Primary;
  Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepWizard');

  Md3Text(WizardForm.PageNameLabel, 20, False);
  WizardForm.PageNameLabel.SetBounds(ScaleX(32), ScaleY(43),
    BodyWidth - ScaleX(64), ScaleY(38));
  Md3Text(WizardForm.PageDescriptionLabel, 10, True);
  WizardForm.PageDescriptionLabel.SetBounds(ScaleX(32), ScaleY(87),
    BodyWidth, ScaleY(30));
  WizardForm.WizardSmallBitmapImage.Stretch := True;
  WizardForm.WizardSmallBitmapImage.SetBounds(WizardForm.ClientWidth - ScaleX(80),
    ScaleY(24), ScaleX(48), ScaleY(48));

  { 主按钮在向导里会换成「安装」「完成」，宽度按三者里最长的取，翻页时不跳。 }
  NextWidth := Md3ButtonWidth([SetupMessage(msgButtonNext),
    SetupMessage(msgButtonInstall), SetupMessage(msgButtonFinish)], ScaleX(96));
  WizardForm.NextButton.SetBounds(WizardForm.ClientWidth - ScaleX(32) - NextWidth,
    FooterTop + ScaleY(20), NextWidth, ScaleY(32));
  BackWidth := Md3ButtonWidth([SetupMessage(msgButtonBack)], ScaleX(84));
  WizardForm.BackButton.SetBounds(WizardForm.NextButton.Left - ScaleX(12) - BackWidth,
    WizardForm.NextButton.Top, BackWidth, ScaleY(32));
  WizardForm.CancelButton.SetBounds(ScaleX(32), WizardForm.NextButton.Top,
    Md3ButtonWidth([SetupMessage(msgButtonCancel)], ScaleX(64)), ScaleY(32));

  { Do not materialize hidden editors or the summary during initialization.
    Inno remains responsible for the paths and complete summary contents. }
  { 那个 Win95 黄纸夹（Inno 内置的 SelectDirBitmapImage）在一屏 MD3 里最扎眼。
    这里选择**隐藏**而不是换成 MD3 图标：换图要 32 位 BMP（TBitmapImage.Bitmap 是
    TBitmap，只吃 BMP），而 TBitmapImage 没有 AlphaFormat 属性，alpha 无人解释、
    圆角外会露黑块，只能把底色烧进图里——那就与「背景随主题变」冲突。整页留白反而
    更贴 MD3。别再为它生成 wizard_folder*.bmp：那批资产与画它们的代码已随本轮删除。 }
  WizardForm.SelectDirBitmapImage.Visible := False;
  Md3Text(WizardForm.SelectDirLabel, 10, True);
  WizardForm.SelectDirLabel.SetBounds(0, 0, BodyWidth, ScaleY(30));
  WizardForm.SelectDirBrowseLabel.Caption := CustomMessage('FushiInstallLocationLabel');
  Md3PathField(WizardForm.DirEdit, WizardForm.DirBrowseButton,
    WizardForm.SelectDirBrowseLabel, ScaleY(52));
  Md3Text(WizardForm.DiskSpaceLabel, 9, True);

  Md3Text(WizardForm.SelectTasksLabel, 10, True);
  WizardForm.SelectTasksLabel.SetBounds(0, 0, BodyWidth, ScaleY(28));
  Md3PrepareTasks(WizardForm.TasksList);
  WizardForm.TasksList.MinItemHeight := ScaleY(30);

  Md3Text(WizardForm.ReadyLabel, 10, True);
  WizardForm.ReadyLabel.SetBounds(0, 0, BodyWidth, ScaleY(28));

  Md3Text(WizardForm.StatusLabel, 10, False);
  Md3Text(WizardForm.FilenameLabel, 9, True);
  Md3InitializeControls();
  Md3StyleButton(WizardForm.NextButton, True);
  Md3StyleButton(WizardForm.BackButton, False);
  Md3StyleButton(WizardForm.CancelButton, False);
  Md3StyleTitleBar(WizardForm.Handle);
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Summary: String;
  DataPageID: Integer;
begin
  DataPageID := -1;
  if DataRootPage <> nil then
    DataPageID := DataRootPage.ID;
  if CurPageID = wpSelectDir then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepProgram');
    Md3FitPathField(WizardForm.DirEdit, WizardForm.DirBrowseButton);
    Md3StyleButton(WizardForm.DirBrowseButton, False);
  end
  else if CurPageID = DataPageID then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepData');
    Md3FitPathField(DataRootPage.Edits[0], DataRootPage.Buttons[0]);
    Md3StyleButton(DataRootPage.Buttons[0], False);
  end
  else if CurPageID = wpSelectTasks then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepPreferences');
    WizardForm.TasksList.SetBounds(0, ScaleY(44), WizardForm.SelectTasksPage.ClientWidth,
      WizardForm.SelectTasksPage.ClientHeight - ScaleY(44));
    Md3StyleTasks(WizardForm.TasksList);
  end
  else if CurPageID = wpReady then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepReady');
    { UpdateReadyPage has finished before CurPageChanged (Inno 6.7). Preserve
      its complete text across VCL handle recreation; do not instantiate a
      styled scrolling control on a hidden notebook page. }
    Summary := WizardForm.ReadyMemo.Lines.Text;
    if Md3SummaryCard = nil then
    begin
      Md3SummaryCard := TPanel.Create(WizardForm);
      Md3SummaryCard.StyleElements := [];
      Md3SummaryCard.ParentBackground := False;
      Md3SummaryCard.BevelOuter := bvNone;
      Md3SummaryCard.Color := Md3SurfaceContainer;
      Md3SummaryCard.TabStop := False;
      Md3SummaryCard.Parent := WizardForm.ReadyPage;
      WizardForm.ReadyMemo.Parent := Md3SummaryCard;
    end;
    Md3SummaryCard.SetBounds(0, ScaleY(40), WizardForm.ReadyPage.ClientWidth,
      WizardForm.ReadyPage.ClientHeight - ScaleY(40));
    WizardForm.ReadyMemo.StyleElements := [];
    WizardForm.ReadyMemo.BorderStyle := bsNone;
    WizardForm.ReadyMemo.Color := Md3SurfaceContainer;
    WizardForm.ReadyMemo.Font.Name := Md3UiFontName(WizardForm.ReadyMemo.Font.Name);
    WizardForm.ReadyMemo.Font.Size := 10;
    WizardForm.ReadyMemo.Font.Color := Md3OnSurface;
    WizardForm.ReadyMemo.ScrollBars := ssNone;
    WizardForm.ReadyMemo.SetBounds(ScaleX(16), ScaleY(14),
      Md3SummaryCard.Width - ScaleX(32), Md3SummaryCard.Height - ScaleY(28));
    WizardForm.ReadyMemo.Lines.Text := Summary;
    Md3StyleSurface(Md3SummaryCard, 12);
  end
  else if CurPageID = wpInstalling then
    Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepInstalling')
  else
    Md3StepLabel.Caption := 'FUSHI  /  ' + CustomMessage('FushiStepWizard');
end;

procedure DeinitializeSetup();
begin
  Md3FinalizeControls();
end;
