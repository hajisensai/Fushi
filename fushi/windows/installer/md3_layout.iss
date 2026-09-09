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
  Container.SetBounds(0, Top, WizardForm.InnerNotebook.Width - ScaleX(96), ScaleY(56));
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
    ScaleX(84), ScaleY(32));
  Md3PrepareButton(Browse);
end;

procedure Md3LayoutDataRootPage();
begin
  DataRootPage.Surface.StyleElements := [];
  DataRootPage.Surface.Color := Md3Surface;
  Md3Text(DataRootPage.SubCaptionLabel, 10, True);
  DataRootPage.SubCaptionLabel.SetBounds(0, 0, DataRootPage.SurfaceWidth, ScaleY(60));
  DataRootPage.PromptLabels[0].Caption := '数据存储位置';
  Md3PathField(DataRootPage.Edits[0], DataRootPage.Buttons[0],
    DataRootPage.PromptLabels[0], ScaleY(84));
end;

procedure Md3FitPathField(Edit: TEdit; Browse: TNewButton);
begin
  { Notebook pages acquire their final client width when activated. Fit both
    native fields from that page, not from its earlier construction bounds. }
  Edit.Parent.Width := Edit.Parent.Parent.ClientWidth - ScaleX(96);
  Edit.Width := Edit.Parent.Width - ScaleX(32);
  Browse.Left := Edit.Parent.Width + ScaleX(12);
  Md3StyleSurface(TPanel(Edit.Parent), 10);
end;

procedure ApplyMd3Chrome();
var
  BodyWidth, FooterTop, PageIndex: Integer;
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
  Md3StepLabel.Caption := 'FUSHI  /  安装向导';

  Md3Text(WizardForm.PageNameLabel, 20, False);
  WizardForm.PageNameLabel.SetBounds(ScaleX(32), ScaleY(43),
    BodyWidth - ScaleX(64), ScaleY(38));
  Md3Text(WizardForm.PageDescriptionLabel, 10, True);
  WizardForm.PageDescriptionLabel.SetBounds(ScaleX(32), ScaleY(87),
    BodyWidth, ScaleY(30));
  WizardForm.WizardSmallBitmapImage.Stretch := True;
  WizardForm.WizardSmallBitmapImage.SetBounds(WizardForm.ClientWidth - ScaleX(80),
    ScaleY(24), ScaleX(48), ScaleY(48));

  WizardForm.NextButton.SetBounds(WizardForm.ClientWidth - ScaleX(128),
    FooterTop + ScaleY(20), ScaleX(96), ScaleY(32));
  WizardForm.BackButton.SetBounds(WizardForm.NextButton.Left - ScaleX(96),
    WizardForm.NextButton.Top, ScaleX(84), ScaleY(32));
  WizardForm.CancelButton.SetBounds(ScaleX(32), WizardForm.NextButton.Top,
    ScaleX(64), ScaleY(32));

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
  WizardForm.SelectDirBrowseLabel.Caption := '安装位置';
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
    Md3StepLabel.Caption := 'FUSHI  /  程序位置';
    Md3FitPathField(WizardForm.DirEdit, WizardForm.DirBrowseButton);
    Md3StyleButton(WizardForm.DirBrowseButton, False);
  end
  else if CurPageID = DataPageID then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  数据位置';
    Md3FitPathField(DataRootPage.Edits[0], DataRootPage.Buttons[0]);
    Md3StyleButton(DataRootPage.Buttons[0], False);
  end
  else if CurPageID = wpSelectTasks then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  使用偏好';
    WizardForm.TasksList.SetBounds(0, ScaleY(44), WizardForm.SelectTasksPage.ClientWidth,
      WizardForm.SelectTasksPage.ClientHeight - ScaleY(44));
    Md3StyleTasks(WizardForm.TasksList);
  end
  else if CurPageID = wpReady then
  begin
    Md3StepLabel.Caption := 'FUSHI  /  确认设置';
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
    Md3StepLabel.Caption := 'FUSHI  /  正在安装'
  else
    Md3StepLabel.Caption := 'FUSHI  /  安装向导';
end;

procedure DeinitializeSetup();
begin
  Md3FinalizeControls();
end;
