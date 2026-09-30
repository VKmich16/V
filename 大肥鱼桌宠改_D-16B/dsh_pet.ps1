# ============================================================================
#  DSH balance pet  (v2)
#
#  A draggable desktop overlay: the character holds a tablet whose screen stays
#  transparent and shows the live DSH balance. Every time the balance drops by
#  the configured step (0.1 CNY by default) the character flashes red and shakes
#  (Minecraft hurt style) and a red "-0.1" floats up above their head.
#
#  v2:
#    - new artwork; the tablet screen is left fully transparent (no fill)
#    - only the balance label + the number are drawn on the screen
#    - right-click -> per-charge amount (default 0.1); the floating number and
#      the screen readout both follow it
#    - drag with the left button only; on release it snaps to the bottom-left
#    - default size 2cm x 2cm, right-click -> size to change it
#    - "refresh now" reports the outcome instead of silently doing nothing
#
#  Windows PowerShell 5.1 + WinForms. No external packages, no admin rights.
#  ASCII-only: PS 5.1 reads .ps1 without a BOM as ANSI, so all UI text lives in
#  C# \uXXXX escapes inside the here-string below.
# ============================================================================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('DshPet' -as [type])) {
Add-Type -ReferencedAssemblies @('System.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Net.Http.dll') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// ------------------------------------------------------------------ utils ---

// Raw ARGB access. Unlock as soon as possible: GDI+ must never draw into a
// bitmap while it is still locked.
// A lock on a bitmap rectangle. P holds only the locked rect (R.Width*4 bytes per
// row), so a lock on the widget's corner of a screen-sized canvas copies 0.8 MB
// instead of 16 MB. Rect-locking matters: Marshal.Copy writes back whole rows, so
// a buffer that spanned the full stride would clobber the columns beside the rect.
public sealed class Buf : IDisposable {
    public readonly Bitmap Bmp;
    public readonly Rectangle R;
    public readonly int W, H;         // size of the locked rectangle
    public readonly int Stride;       // bytes per row inside the rect (= W*4)
    public readonly byte[] P;
    readonly BitmapData _d;

    public Buf(Bitmap b) : this(b, new Rectangle(0, 0, b.Width, b.Height)) { }

    public Buf(Bitmap b, Rectangle r) {
        Bmp = b; R = r; W = r.Width; H = r.Height;
        _d = b.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        Stride = W * 4;
        P = new byte[Stride * H];
        for (int y = 0; y < H; y++) Marshal.Copy(IntPtr.Add(_d.Scan0, y * _d.Stride), P, y * Stride, Stride);
    }
    public void Flush() {
        for (int y = 0; y < H; y++) Marshal.Copy(P, y * Stride, IntPtr.Add(_d.Scan0, y * _d.Stride), Stride);
    }
    public void Dispose() { Bmp.UnlockBits(_d); }
}

public static class Cs {
    // src over dst with straight (non-premultiplied) alpha
    public static void Blend(byte[] d, int i, int r, int g, int b, double a) {
        if (a <= 0) return;
        if (a > 1) a = 1;
        double da = d[i + 3] / 255.0;
        double oa = a + da * (1 - a);
        if (oa <= 0.0001) { d[i] = 0; d[i+1] = 0; d[i+2] = 0; d[i+3] = 0; return; }
        d[i]     = (byte)Math.Round((b * a + d[i]     * da * (1 - a)) / oa);
        d[i + 1] = (byte)Math.Round((g * a + d[i + 1] * da * (1 - a)) / oa);
        d[i + 2] = (byte)Math.Round((r * a + d[i + 2] * da * (1 - a)) / oa);
        d[i + 3] = (byte)Math.Round(oa * 255);
    }
}

internal static class Native {
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst,
        ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi,
        uint usage, out IntPtr bits, IntPtr section, uint offset);
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO {
        public BITMAPINFOHEADER bmiHeader;
        public int bmiColors;
    }
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObj);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    public const int ULW_ALPHA = 0x02;
    public const byte AC_SRC_OVER = 0x00;
    public const byte AC_SRC_ALPHA = 0x01;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WM_NCHITTEST = 0x0084;
    public const int HTTRANSPARENT = -1;
    public const int HTCLIENT = 1;
}

// ------------------------------------------------------------- animations ---

sealed class Hit {
    public double T;
    public const double Dur = 0.55;
    public bool Done { get { return T >= Dur; } }
    public double Pulse {
        get {
            if (T < 0.20) return 1.0;                       // solid flash on impact
            double e = Math.Max(0, 1 - (T - 0.20) / (Dur - 0.20));
            return Math.Sin((T - 0.20) * 26) * 0.55 * e * e;
        }
    }
}

sealed class Floater {
    public double T, Dur = 1.05, Jitter;
    public int X, Y;
    public string Text;
    // Feed hearts reuse this list: blocky pixel hearts that rise and fade,
    // sized individually so a burst reads as "big and small mixed together".
    public bool Hearts;
    public int HeartSize;
    public double HeartPhase, Drift;
    public bool Done { get { return T >= Dur; } }
}

// Small modal input dialog. ShowDialog pumps its own loop, so it works on top
// of the layered main window.
sealed class InputDialog : Form {
    readonly TextBox _box;
    public InputDialog(string title, string prompt, string unit, string initial) {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false; MinimizeBox = false;
        ClientSize = new Size(330, 140);
        TopMost = true;

        Label lab = new Label();
        lab.Text = prompt;
        lab.SetBounds(14, 10, 300, 34);
        Controls.Add(lab);

        _box = new TextBox();
        _box.Text = initial;
        _box.SetBounds(14, 46, 230, 24);
        Controls.Add(_box);

        Label u = new Label();
        u.Text = unit;
        u.SetBounds(250, 49, 70, 20);
        Controls.Add(u);

        Button ok = new Button();
        ok.Text = "OK";
        ok.DialogResult = DialogResult.OK;
        ok.SetBounds(155, 88, 75, 26);
        Controls.Add(ok);

        Button cancel = new Button();
        cancel.Text = "Cancel";
        cancel.DialogResult = DialogResult.Cancel;
        cancel.SetBounds(240, 88, 75, 26);
        Controls.Add(cancel);

        AcceptButton = ok; CancelButton = cancel;
        _box.SelectAll();
        _box.Focus();
    }
    public string Value { get { return _box.Text.Trim(); } }
}

// ---------------------------------------------------------------- sound ----
//
// Overlapping hit sounds through the Win32 MCI interface: every cue is played
// on its own alias, so a new hit never cuts off the previous one.
public sealed class SoundPool {
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    static extern int mciSendStringW(string cmd, StringBuilder ret, int len, IntPtr hwnd);
    static string Send(string cmd) {
        StringBuilder sb = new StringBuilder(256);
        mciSendStringW(cmd, sb, sb.Capacity, IntPtr.Zero);
        return sb.ToString();
    }

    // mciSendString reports failure through its RETURN CODE and leaves the reply
    // buffer empty either way, so testing the buffer for emptiness marks every
    // failed "open" as a success. Only the return code is a usable signal.
    static bool SendOk(string cmd) {
        StringBuilder sb = new StringBuilder(256);
        return mciSendStringW(cmd, sb, sb.Capacity, IntPtr.Zero) == 0;
    }

    readonly string _path;
    readonly int _slots;
    readonly string[] _alias;
    readonly bool[] _open;
    readonly string _logPath;
    public bool Failed; public string Error = ""; public int Plays;

    public SoundPool(string path, int slots, int volumePercent, string logPath)
        : this(path, slots, volumePercent, logPath, "dsphpet") { }

    // tag keeps MCI alias names unique: two pools sharing "dsphpet0" would close
    // each other's files, so the feed sound needs its own prefix.
    public SoundPool(string path, int slots, int volumePercent, string logPath, string tag) {
        _path = path; _slots = slots; _logPath = logPath;
        _volumePercent = volumePercent;
        _alias = new string[slots]; _open = new bool[slots];
        try {
            // The ABSOLUTE path is what MCI accepts. It used to cd into the sound's
            // folder and open the bare file name, on the theory that a non-ASCII
            // path gets mangled - but a bare name fails outright with "file not
            // found" no matter what the working directory is, and the full-path
            // retry below never ran because the success test looked at the reply
            // buffer instead of the return code. Result: the cue could never play.
            for (int i = 0; i < slots; i++) {
                _alias[i] = tag + i;
                Send("close " + _alias[i]);
                _open[i] = SendOk("open \"" + path + "\" type mpegvideo alias " + _alias[i]);
                if (_open[i]) Send("setaudio " + _alias[i] + " volume to " + volumePercent * 10);
            }
            if (!_open[0]) { Failed = true; Error = "cannot open " + path; }
        } catch (Exception ex) { Failed = true; Error = ex.Message; }
    }

    // Live volume change, for the menu. MCI wants 0..1000 (percent * 10).
    public void SetVolume(int percent) {
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;
        _volumePercent = percent;
        if (Failed) return;
        try {
            for (int i = 0; i < _slots; i++)
                if (_open[i]) Send("setaudio " + _alias[i] + " volume to " + (percent * 10));
        } catch { }
    }
    public int VolumePercent { get { return _volumePercent; } }
    int _volumePercent = 80;

    // plays on a free alias and returns its index, or -1 when nothing played
    public int Play() {        if (Failed) return -1;
        try {
            for (int attempt = 0; attempt < 2; attempt++) {
                for (int i = 0; i < _slots; i++) {
                    if (!_open[i]) continue;
                    if (Send("status " + _alias[i] + " mode").IndexOf("playing") >= 0) continue;
                    Send("seek " + _alias[i] + " to start");
                    Send("play " + _alias[i]);
                    Plays++;
                    return i;
                }
                // every slot is busy: reopen the first so a burst still overlaps
                if (attempt == 0) {
                    Send("close " + _alias[0]);
                    _open[0] = SendOk("open \"" + _path + "\" type mpegvideo alias " + _alias[0]);
                }
            }
        } catch (Exception ex) {
            Failed = true; Error = ex.Message;
            try { File.AppendAllText(_logPath, DateTime.Now.ToString("s") + " sound: " + ex.Message + "\r\n"); } catch { }
        }
        return -1;
    }

    public void Dispose() {
        try { for (int i = 0; i < _slots; i++) if (_open[i]) Send("close " + _alias[i]); } catch { }
    }
}
// ------------------------------------------------------------------ window ---

// The recharge bowl. Coordinates are SCREEN pixels - it is its own window, see
// the widget's window. Position is the CENTRE in SCREEN pixels and the footprint
// is a circle.
public sealed class Rice {
    public double X, Y;              // centre, in screen pixels
    public double VX, VY;
    public double R;                 // footprint radius
    public double Amount;            // the top-up this bowl carries
    public int Bounces;
    // How many bounces the CURRENT fall is allowed. Set when the bowl is released:
    // a drop from high up bounces more than one released just above the floor, and a
    // bowl re-thrown off a shelf gets a fresh allowance.
    public int MaxBounces;
    public double Squish;            // 0..1, drives the squash/stretch
    public double Rot;               // small wobble, radians
    public double SquishT;           // seconds since the last impact
    public double SquishDur;         // how long that impact's wobble lasts
    public bool Grounded, Dragging;
    public bool LandedLogged;        // diagnostics: landing line printed once
    public bool Fed;                 // delivered to the girl -> fade out
    public double FedAmount;         // what it actually paid out (the floater text)
    public double DieT;
}


// A flat, roomy menu renderer. The stock Professional renderer draws a grey
// gradient gutter, cramped rows and a heavy tick, which is what made the menu
// look unfinished.
sealed class PetMenuRenderer : ToolStripProfessionalRenderer {
    public static readonly Color Ink  = Color.FromArgb(255, 36, 42, 54);
    static readonly Color Hover = Color.FromArgb(255, 233, 240, 254);
    static readonly Color Accent = Color.FromArgb(255, 64, 132, 240);

    public PetMenuRenderer() : base(new PetColors()) {
        RoundedEdges = false;              // square corners read as deliberate
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        Rectangle r = new Rectangle(Point.Empty, e.ToolStrip.Size);
        using (SolidBrush b = new SolidBrush(Color.White)) e.Graphics.FillRectangle(b, r);
    }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        Rectangle r = new Rectangle(Point.Empty, e.ToolStrip.Size);
        r.Width -= 1; r.Height -= 1;
        using (Pen p = new Pen(Color.FromArgb(255, 214, 220, 230))) e.Graphics.DrawRectangle(p, r);
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = Ink;
        base.OnRenderItemText(e);          // white/blue fill happens in OnRenderMenuItemBackground
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected && !e.Item.Pressed) return;
        Rectangle r = new Rectangle(2, 0, e.Item.Width - 4, e.Item.Height);
        using (SolidBrush b = new SolidBrush(Hover)) e.Graphics.FillRectangle(b, r);
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        int y = e.Item.Height / 2;
        using (Pen p = new Pen(Color.FromArgb(255, 228, 232, 238)))
            e.Graphics.DrawLine(p, 10, y, e.Item.Width - 10, y);
    }
    // A slim chevron instead of the stock black triangle, in the accent colour
    // while the row is hot.
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        Graphics g = e.Graphics;
        SmoothingMode old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = e.ArrowRectangle;
        float cx = r.Left + r.Width / 2f;
        float cy = r.Top + r.Height / 2f;
        bool hot = e.Item.Selected || e.Item.Pressed;
        using (Pen p = new Pen(hot ? Accent : Color.FromArgb(255, 138, 148, 166), 1.6f)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            g.DrawLines(p, new PointF[] {
                new PointF(cx - 1.6f, cy - 3.4f),
                new PointF(cx + 1.8f, cy),
                new PointF(cx - 1.6f, cy + 3.4f) });
        }
        g.SmoothingMode = old;
    }

    // Draw our own tick: a rounded accent square with a white check, centred on
    // the icon column. With ShowCheckMargin off, e.ImageRectangle IS the icon
    // column, so a checkable row carries the tick instead of an icon.
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Graphics g = e.Graphics;
        SmoothingMode old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int s = 13;
        Rectangle r = e.ImageRectangle;
        int x = r.Width > 0 ? r.X + (r.Width - s) / 2 : 3;
        int y = (e.Item.Height - s) / 2;
        using (SolidBrush b = new SolidBrush(Accent)) {
            using (GraphicsPath path = RoundedSquare(new Rectangle(x, y, s, s), 3)) g.FillPath(b, path);
        }
        using (Pen p = new Pen(Color.White, 1.9f)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            g.DrawLines(p, new PointF[] {
                new PointF(x + 3.4f, y + 6.8f),
                new PointF(x + 5.6f, y + 9.0f),
                new PointF(x + 9.8f, y + 4.0f)
            });
        }
        g.SmoothingMode = old;
    }

    static GraphicsPath RoundedSquare(Rectangle r, int radius) {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    sealed class PetColors : ProfessionalColorTable {
        public override Color MenuItemSelected { get { return Hover; } }
        public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
        public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
        public override Color MenuItemBorder { get { return Hover; } }
        public override Color MenuBorder { get { return Color.FromArgb(255, 214, 220, 230); } }
        public override Color MenuItemPressedGradientBegin { get { return Hover; } }
        public override Color MenuItemPressedGradientEnd { get { return Hover; } }
        public override Color ToolStripDropDownBackground { get { return Color.White; } }
        public override Color ImageMarginGradientBegin { get { return Color.White; } }
        public override Color ImageMarginGradientMiddle { get { return Color.White; } }
        public override Color ImageMarginGradientEnd { get { return Color.White; } }
        public override Color SeparatorDark { get { return Color.FromArgb(255, 228, 232, 238); } }
        public override Color SeparatorLight { get { return Color.FromArgb(255, 228, 232, 238); } }
    }
}

public sealed class DshPet : Form {
    const string S_LABEL   = "DSH \u4F59\u989D";                                    // DSH balance
    const string S_HELP    = "\u6F14\u793A\u8FDE\u7EED\u6263\u8D39";                // demo consecutive charges
    const string S_SIZE    = "\u5C3A\u5BF8";                                        // size
    const string S_REFRESH = "\u7ACB\u5373\u5237\u65B0\u4F59\u989D";                // refresh now
    const string S_TEST    = "\u6D4B\u8BD5\u4E00\u6B21\u6263\u8D39\u6548\u679C";    // test one charge
    const string S_QUIT    = "\u9000\u51FA";                                        // quit
    const string S_CUSTOM  = "\u81EA\u5B9A\u4E49...";                               // custom...
    const string S_HELPT   = "\u6F14\u793A\u6263\u8D39\u91D1\u989D";
    const string S_HELPP   = "\u8981\u6F14\u793A\u6263\u591A\u5C11\u94B1\uFF08\u5143\uFF09";
    const string S_SIZET   = "\u5C3A\u5BF8";
    const string S_SIZEP   = "\u5BBD\u9AD8\uFF08\u5398\u7C73\uFF09";
    const string S_NOKEY   = "\u7F3A\u5C11 API Key";
    const string S_LOADING = "\u8FDE\u63A5\u4E2D...";
    const string S_KEYT    = "API Key";
    const string S_KEYP    = "\u7C98\u8D34 DeepSeek API Key\uFF08\u7559\u7A7A\u5219\u4E0D\u4FEE\u6539\uFF09";
    const string S_SETKEY  = "\u8BBE\u7F6E API Key";
    // Recharge rehearsal: drives the real top-up path locally so the bowl can be
    // tested without paying. Default amount is a plain 3 yuan.
    const string S_TOPT    = "\u6D4B\u8BD5\u5145\u503C\u91D1\u989D";
    const string S_TOPP    = "\u8981\u6A21\u62DF\u5145\u591A\u5C11\u94B1\uFF08\u5143\uFF09";
    const string S_TESTTOP   = "\u6D4B\u8BD5\u5145\u503C\u52A8\u753B";              // test top-up animation
    const string S_TESTTOPG  = "\u6A21\u62DF\u5145\u503C 3 \u5143\uFF08\u6389\u7C73\u996D\u76C6\uFF09";
    const double TestTopUpYuan = 3.0;
    // Size presets. The cup names are the joke the user asked for; the stored
    // unit is PIXELS because a centimetre is not a fixed number of pixels.
    const string S_MID     = "\u4E2D\u676F";                                        // mid cup
    const string S_BIG     = "\u5927\u676F";                                        // big cup
    const string S_XL      = "\u8D85\u5927\u676F";                                  // extra large cup
    const string S_PXT     = "\u81EA\u5B9A\u4E49\u5C3A\u5BF8";
    const string S_PXP     = "\u8FB9\u957F\uFF08\u50CF\u7D20\uFF0C\u6B63\u65B9\u5F62\uFF09";
    const string S_PXLBL   = " px";
    static readonly string[] SizeNames = new string[] { S_MID, S_BIG, S_XL };

    // ---- menu appearance ----
    // Icons are DRAWN, not taken from a font. The Emoji font is monochrome under
    // GDI and ToolStrip rescales any image that is not exactly ImageScalingSize
    // (16x16) to fit, so font glyphs came out as soft black blobs. Small vectors
    // are crisp, consistent, and can carry a colour.
    const int IC_NONE    = 0;
    const int IC_REFRESH = 1;
    const int IC_BOLT    = 2;
    const int IC_BOWL    = 3;
    const int IC_CASCADE = 4;
    const int IC_SIZE    = 5;
    const int IC_SOUND   = 6;
    const int IC_KEY     = 7;
    const int IC_QUIT    = 8;
    const int IC_MUTE    = 9;

    // Volume submenu. Five steps plus mute; the level is stored in state.ini.
    static readonly int[] VolumeSteps = new int[] { 0, 25, 50, 75, 100 };
    const string S_SOUND   = "\u58F0\u97F3";                                   // sound
    const string S_SOUNDON = "\u5F00\u542F\u58F0\u97F3";                       // sound on
    const string S_MUTE0   = "\u9759\u97F3 (0 %)";                             // muted level
    const string S_VOLT    = "\u97F3\u91CF\u5927\u5C0F";                       // volume level
    const string S_VOLP    = "\u65B0\u97F3\u91CF\uFF080-100\uFF09";            // new volume (0-100)

    readonly string _baseDir;
    readonly string _apiUrl;
    readonly int _pollMs;
    string _apiKey;
    // Two credential shapes are supported. An sk- API Key talks to
    // api.deepseek.com with an Authorization: Bearer header. A DSH account grant
    // (deepseek-account-platform/default) instead carries token + issuer, uses the
    // x-dsh-auth-token header and answers with a different JSON shape.
    bool _isAccount;
    string _token;
    bool _noSave;                // set by the diagnostic entry points

    Bitmap _flat, _sprNormal, _sprRed, _canvas;
    double _scale = 1.0;
    int _w, _h;
    double[] _fx, _fy;
    double _cm = 8.0;            // legacy edge length in centimetres, kept so an
                                 // existing state.ini keeps working
    // The WINDOW can be bigger than the widget: while a top-up bowl is in flight it
    // covers the whole screen so the bowl can fall from the real right edge of the
    // monitor. The widget is then drawn at _offX/_offY inside it.
    int _winW, _winH;            // canvas / window size
    int _offX, _offY;            // where the widget sits inside the window
    bool _fullScreen;            // window currently spans the virtual screen
    // Edge length in DEVICE PIXELS, which is what the presets and the custom
    // entry actually store. When this is set it wins over _cm: pixels do not
    // change meaning when the monitor or its scaling does.
    int _sizePx;
    static readonly int[] PresetPx = new int[] { 340, 454, 624 };   // mid / big / XL
    int _headX, _headY;

    readonly List<Hit> _hits = new List<Hit>();
    readonly List<Floater> _floaters = new List<Floater>();
    readonly System.Windows.Forms.Timer _timer, _poll;
    volatile bool _dirty = true;
    volatile int _pollWant = 1;      // 0 = idle, 1 = auto (stepwise), 2 = snap to latest

    // Every deduction is exactly one cent, spaced 0.5s apart.
    //
    // The printed number is NOT tracked on its own - it is defined as
    // (_bookedBal - _testOffset), and _bookedBal is only ever moved inside the
    // cue firing code. Everything else works on the pair below, so the number
    // simply cannot drift away from the animation:
    //
    //   _bookedAt  balance the booking corresponds to
    //   _bookedBal number printed when the balance was _bookedAt
    //
    // When the server reports a new balance the whole difference
    // (_bookedAt - bal) is queued; it is then paid off one cent per cue, so a
    // 0.05 jump plays five complete animations. The step is deliberately fixed
    // at one cent: that is the unit the API reports in, so there is never a
    // remainder left over, which is what used to let the number move without an
    // animation.
    const double StepYuan = 0.01;
    // One complete animation every 0.2s. Cues no longer wait for the previous
    // number to finish flying, so this value IS the rhythm; the numbers stack up
    // as a comet trail instead of repeating in place.
    const double CueGapSec = 0.2;
    // Quiet period after a bowl is delivered, so a demonstration is not immediately
    // interrupted by the spending animation (see the tick loop).
    const double FeedGraceSec = 2.0;
    double _cueGrace;                // seconds left of that quiet period
    const int MaxCuesPerPoll = 40;   // ceiling on catch-up after a big jump

    double _realBal = double.NaN;
    double _bookedAt = double.NaN;
    double _bookedBal = double.NaN;
    double _testOffset = 0;          // display-only offset from test cues
    double _pending = 0;             // booked difference not yet charged
    double _pendingStep = 0;         // amount of the step being paid off
    double _dueGap;                  // seconds until the next cue may fire
    double _lastCueAmount = 0;       // amount of the most recent cue (diagnostics)
    float _floaterStep = 20f;        // vertical spacing of the number trail, in pixels

    double DrawnBalance {
        get {
            if (double.IsNaN(_bookedBal)) return double.NaN;
            double v = _bookedBal - _testOffset;
            return Math.Round(v < 0 ? 0 : v, 2);
        }
    }
    string _status = S_LOADING;
    volatile bool _connected;
    volatile string _lastPollResult = "";

    bool _drag; Point _dragStart;
    Point _offStart;                 // widget offset when a girl-drag began
    bool _snapping; double _snapT; Point _snapFrom, _snapTo;
    byte[] _hitMap; int _hitW, _hitH;
    // The GIRL only - _hitMap also contains the top-up bowl (so the bowl can be
    // grabbed), and using that for the "did the bowl land on her" test compared
    // the bowl against itself and was always true. That made any stray click
    // deliver the bowl and the balance look like it climbed on its own.
    byte[] _charHitMap;
    // Cached silhouette of the girl (the sprite's alpha) + where it was last
    // stamped into _charHitMap. SnapshotGirl used to rebuild a canvas-sized
    // bitmap and rescan the whole canvas every frame while a bowl was out.
    byte[] _girlAlpha; int _girlAlphaW, _girlAlphaH;
    byte[] _girlStampedOn; int _girlStampX, _girlStampY; bool _girlStamped;
    // Rects painted this frame / last frame, so the next frame can erase exactly
    // those instead of memsetting the whole screen-sized canvas.
    readonly List<Rectangle> _paintRects = new List<Rectangle>();
    readonly List<Rectangle> _lastRects = new List<Rectangle>();
    Rectangle _dirtyRect;            // canvas area that changed this frame (for the push)
    Rectangle _lastWidgetRect;       // where the widget was drawn last frame
    bool _widgetWasAnimating;        // so the frame an animation ends on still repaints
    Bitmap _lastCanvas;              // a new canvas forces a full widget repaint
    string _lastPanelKey;            // tablet text + connection state
    // What the tablet shows: the panel bitmap is rebuilt from this, so a change here
    // means the widget must be repainted even when nothing is animating.
    string PanelKey() {
        return (_connected ? "1" : "0") + (_lastPollResult.Length > 0 ? "1" : "0") + "|" + DrawnText;
    }
    // DSHPET_ULWBLT=0 falls back to building an HBITMAP for every push; the DIB
    // route is the default and the two are A/B tested by --ulwcheck.
    bool _ulwBlt = true;

    // ------------------------------------------------------------ top-up ---
    // A recharge shows up as the server balance rising. The readout must NOT
    // follow it on its own: a bowl of rice drops in from the right, and the
    // printed number only climbs back once the player drags that bowl onto the
    // girl. Until then the difference sits in _creditPending and stays invisible.
    Bitmap _riceFlat;                // rice.png as loaded, unscaled
    Bitmap _riceArt;                 // rice.png, scaled for the current widget size
    Bitmap _heartArt;                // one pixel heart, drawn at several sizes
    readonly List<Floater> _hearts = new List<Floater>();
    double _creditPending;           // recharged money not yet collected
    // The top-up is credited in ONE step inside OnRiceFed(), at the moment of
    // delivery. There is deliberately no interpolation state: no target, no start
    // value, no timer, and no flag that a background path could trip.
    readonly Random _rng = new Random();

    // Rice bowl physics. Position is the CENTRE in SCREEN pixels and the
    // footprint is a circle, which keeps the floor/overlap maths free of any need
    // to inspect the bitmap's geometry. The bowl lives in its own window
    // in SCREEN pixels so it falls from the edge of the MONITOR, not the widget.
    // All bowls currently on screen. One top-up = one bowl, so several can be in
    // flight at once (a real recharge that lands twice, or the menu rehearsal used
    // repeatedly). _rice points at the one being dragged / most recently dropped,
    // which lets the grab-and-drop code stay single-bowl.
    readonly List<Rice> _rices = new List<Rice>();
    Rice _rice;                      // most recently dropped (the "active" bowl)
    Rice _riceGrab;                  // the bowl currently held by the mouse
    // gravity / restitution / bounce cap (the bowl's motion is stepped in UpdateRice)
    const double RiceGravity = 2100.0;
    const double RiceRestitution = 0.5;
    // Bounces allowed per FALL, not per bowl: land, settle, then throw it off a high
    // shelf and it bounces again. Counting them for the bowl's whole life meant a
    // re-thrown bowl was dead on arrival. The per-fall allowance is Rice.MaxBounces.
    const int RiceMaxBounces = 3;

    // How many bounces a fall is worth, by DROP HEIGHT (screen pixels):
    //   high -> 3   medium -> 2   low -> 1   just above the floor -> 0
    // A flat three bounces felt wrong: releasing the bowl a few pixels off the floor
    // should not rattle three times.
    static int BouncesForDrop(double dropPx) {
        if (dropPx < 60) return 0;
        if (dropPx < 260) return 1;
        if (dropPx < 700) return 2;
        return 3;
    }
    double _riceGrabX, _riceGrabY;   // centre offset from the cursor when grabbed
    NotifyIcon _tray;
    ContextMenuStrip _menu;
    ToolStripMenuItem _sizeItem;
    ToolStripMenuItem _soundItem;
    ToolStripMenuItem _muteItem;
    int _volume = 80;                // 0..100, live from the sound submenu
    // kept in a field so the renderer can be disposed with the form
    PetMenuRenderer _menuRenderer;
    int _demoLeft;                   // cues left in a rehearsal run
    double _demoAmount = 0.01;

    // current frame's shake offset, so the readout and the floating numbers move
    // together with the character
    double _shakeX, _shakeY;
    // hit sound: one MCI alias per concurrent cue
    SoundPool _sound;
    SoundPool _feedSound;            // the delivery "thank you" cue
    bool _soundEnabled = true;
    bool _soundWanted = true;
    volatile bool _noNetwork;        // set by the offline self-tests
    int _pollInFlight;               // only one balance request at a time
    double _bankedBal; bool _bankedSnap; bool _bankedValid;

    public DshPet(string baseDir, string[] args) {
        _baseDir = baseDir;
        // The window is the WHOLE screen from the moment it is created and never
        // changes size. It used to be widget-sized and grow when a bowl appeared; the
        // resize made Windows composite the previous canvas onto the new window for a
        // couple of frames, flashing the girl to the top-left of the screen. Setting
        // it here (before the handle exists) means no resize ever happens.
        // The widget lives at _offX/_offY inside this canvas.
        Rectangle vsInit = SystemInformation.VirtualScreen;
        _winW = vsInit.Width;
        _winH = vsInit.Height;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        SetBounds(vsInit.Left, vsInit.Top, _winW, _winH);
        _apiKey  = Get("DSHPET_KEY", "");
        _apiUrl  = Get("DSHPET_API", "https://api.deepseek.com/user/balance");
        _isAccount = Get("DSHPET_AUTH", "key") == "account";
        _token     = Get("DSHPET_TOKEN", "");
        Log("credentials: " + CredentialSource + ", endpoint=" + _apiUrl);
        _pollMs  = int.Parse(Get("DSHPET_POLL_MS", "2000"));
        _cm      = double.Parse(Get("DSHPET_CM", "8"), CultureInfo.InvariantCulture);
        _soundWanted = Get("DSHPET_SOUND", "1") != "0";
        _ulwBlt = Get("DSHPET_ULWBLT", "1") != "0";
        _volume  = int.Parse(Get("DSHPET_VOLUME", "80"));   // ReadState may override

        string sprite = Get("DSHPET_SPRITE", Path.Combine(baseDir, "sprite.png"));
        if (!File.Exists(sprite)) throw new FileNotFoundException("sprite not found: " + sprite);
        _flat = new Bitmap(sprite);

        // Top-up props. Both are optional: if the files are missing the recharge
        // still works, it just has no bowl to drag and no hearts to pop.
        string ricePath = Path.Combine(baseDir, Get("DSHPET_RICE_FILE", "rice.png"));
        if (File.Exists(ricePath)) {
            try { _riceFlat = new Bitmap(ricePath); } catch (Exception ex) { Log("rice art failed: " + ex.Message); }
        }
        _heartArt = BuildHeartArt();

        // hit sound (mp3) - opens a small pool of MCI aliases up front so the
        // very first cue has no lag and overlapping cues do not cut each other.
        // The path is built here from baseDir rather than handed over through
        // the environment: values crossing the PowerShell/C# boundary come back
        // ANSI-mangled when the folder name is not ASCII, while a path built in
        // this process stays correct.
        string sndPath = Path.Combine(baseDir, Get("DSHPET_SOUND_FILE", "hit.mp3"));
        if (_soundWanted && File.Exists(sndPath)) {
            _sound = new SoundPool(sndPath, 4, _volume, Path.Combine(baseDir, "pet.log"));
            if (_sound.Failed) Log("sound pool failed: " + _sound.Error);
            else Log("sound ready: " + sndPath + " volume=" + _volume);
        } else if (_soundWanted) {
            Log("sound file missing: " + sndPath + " (hit sound disabled)");
        }

        // The "thank you" cue played when a bowl is delivered. Its own pool, with its
        // own alias tag, so it plays independently of the hurt cue.
        string feedPath = Path.Combine(baseDir, Get("DSHPET_FEED_SOUND_FILE", "feed.mp3"));
        if (_soundWanted && File.Exists(feedPath)) {
            _feedSound = new SoundPool(feedPath, 2, _volume, Path.Combine(baseDir, "pet.log"), "dsphfeed");
            if (_feedSound.Failed) Log("feed sound failed: " + _feedSound.Error);
            else Log("feed sound ready: " + feedPath + " volume=" + _volume);
        } else if (_soundWanted) {
            Log("feed sound missing: " + feedPath + " (feed cue disabled)");
        }

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Text = "DSH Balance Pet";

        ReadState();
        Relayout();
        SnapToCorner(true);
        BuildMenu();

        // Shared copy, first run: nothing configured a key, so ask once instead
        // of leaving the tablet stuck on "--". Cancelling keeps it offline.
        bool quietRun = Array.IndexOf(args, "--selftest") >= 0 || Array.IndexOf(args, "--shot") >= 0 ||
                        Array.IndexOf(args, "--menushot") >= 0;
        if (!HasSecret && !quietRun && !File.Exists(KeyPath)) {
            using (InputDialog d = new InputDialog(S_KEYT, S_KEYP, "", "")) {
                if (d.ShowDialog(this) == DialogResult.OK) {
                    string k = d.Value;
                    if (k.Length > 0) {
                        _apiKey = k;
                        SaveKey(k);
                        Log("api key saved on first run (length " + k.Length + ")");
                    }
                } else {
                    Log("first run: no key entered, staying offline until one is set");
                }
            }
        }

        _tray = new NotifyIcon();
        _tray.Icon = SystemIcons.Application;
        _tray.Text = "DSH - " + (_status.Length > 40 ? _status.Substring(0, 40) : _status);
        _tray.ContextMenuStrip = _menu;
        _tray.Visible = true;
        _tray.DoubleClick += delegate { DemoCharge(0.05); };

        _timer = new System.Windows.Forms.Timer();
        _timer.Interval = int.Parse(Get("DSHPET_TICK_MS", "33"));
        _timer.Tick += delegate { OnTick(); };
        _timer.Start();

        _poll = new System.Windows.Forms.Timer();
        _poll.Interval = _pollMs < 1000 ? 1000 : _pollMs;
        _poll.Tick += delegate { if (!_noNetwork) _pollWant = 1; };
        _poll.Start();

        PushLayer();
    }

    static string Get(string n, string f) {
        string v = Environment.GetEnvironmentVariable(n);
        return string.IsNullOrEmpty(v) ? f : v;
    }

    // The credential a request is actually signed with: the account grant token
    // in account mode, the sk- API Key otherwise.
    string Secret { get { return _isAccount ? _token : _apiKey; } }
    bool HasSecret { get { return !string.IsNullOrEmpty(Secret); } }

    string CredentialSource {
        get {
            if (_isAccount) return "DSH account grant";
            return _apiKey.Length > 0 ? "API key" : "none";
        }
    }

    // Builds one menu entry: a drawn icon plus the label.
    ToolStripMenuItem NewItem(int icon, string text) {
        ToolStripMenuItem it = new ToolStripMenuItem(text);
        if (icon != IC_NONE) it.Image = MakeIcon(icon);
        return it;
    }

    // A non-clickable section header, to break the menu into readable groups.
    ToolStripMenuItem NewHeader(string text) {
        ToolStripMenuItem it = new ToolStripMenuItem(text);
        it.Enabled = false;
        it.Padding = new Padding(2, 5, 8, 1);
        return it;
    }

    static readonly Color IconInk    = Color.FromArgb(255, 62, 72, 92);
    static readonly Color IconAccent = Color.FromArgb(255, 64, 132, 240);
    static readonly Color IconAmber  = Color.FromArgb(255, 226, 150, 40);
    static readonly Color IconGreen  = Color.FromArgb(255, 56, 168, 96);
    static readonly Color IconRed    = Color.FromArgb(255, 208, 80, 80);

    // 16x16 exactly: ToolStrip scales an image that does not match
    // ImageScalingSize, and a resampled 16px icon is exactly the mush we are
    // replacing. Everything is drawn inside a 16x16 box with 1.5px strokes.
    static Bitmap MakeIcon(int kind) {
        Bitmap bmp = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            switch (kind) {
            case IC_REFRESH: {          // circular arrow, accent blue
                // 285 degrees of arc with the opening at the top right, and a
                // separate head at the end so the two do not fuse into a blob.
                using (Pen p = new Pen(IconAccent, 1.7f))
                    g.DrawArc(p, 2.6f, 3.0f, 11.2f, 11.2f, 330f, 285f);
                using (SolidBrush b = new SolidBrush(IconAccent))
                    g.FillPolygon(b, new PointF[] {
                        new PointF(10.6f, 2.2f), new PointF(7.1f, 0.9f), new PointF(6.2f, 5.0f) });
                break;
            }
            case IC_BOLT: {             // one charge: a bolt
                PointF[] bolt = new PointF[] {
                    new PointF(9.4f, 1.0f), new PointF(3.6f, 9.0f), new PointF(7.2f, 9.0f),
                    new PointF(6.4f, 15.0f), new PointF(12.4f, 6.6f), new PointF(8.6f, 6.6f) };
                using (SolidBrush b = new SolidBrush(IconAmber)) g.FillPolygon(b, bolt);
                using (Pen p = new Pen(Color.FromArgb(255, 170, 104, 16), 1.0f)) g.DrawPolygon(p, bolt);
                break;
            }
            case IC_BOWL: {             // the falling bowl, with rice in it
                using (SolidBrush b = new SolidBrush(Color.FromArgb(255, 252, 236, 196)))
                    g.FillEllipse(b, 3.6f, 4.4f, 8.8f, 6.4f);
                using (Pen p = new Pen(Color.FromArgb(255, 226, 150, 40), 1.1f))
                    g.DrawEllipse(p, 3.6f, 4.4f, 8.8f, 6.4f);
                using (SolidBrush b = new SolidBrush(IconAccent))
                    g.FillPie(b, 1.4f, 6.2f, 13.2f, 9.0f, 0f, 180f);
                using (Pen p = new Pen(Color.FromArgb(255, 32, 78, 168), 1.2f))
                    g.DrawLine(p, 1.4f, 10.7f, 14.6f, 10.7f);
                break;
            }
            case IC_CASCADE: {          // a run of cues: three chevrons
                using (Pen p = new Pen(IconGreen, 1.8f)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    p.LineJoin = LineJoin.Round;
                    for (int i = 0; i < 3; i++) {
                        float x = 2.6f + i * 4.1f;
                        g.DrawLines(p, new PointF[] {
                            new PointF(x, 3.4f), new PointF(x + 3.0f, 8.0f), new PointF(x, 12.6f) });
                    }
                }
                break;
            }
            case IC_SIZE: {             // a ruler
                using (SolidBrush b = new SolidBrush(Color.FromArgb(255, 222, 233, 254)))
                    g.FillRectangle(b, 1.0f, 5.0f, 14.0f, 6.0f);
                using (Pen p = new Pen(IconAccent, 1.2f))
                    g.DrawRectangle(p, 1.0f, 5.0f, 14.0f, 6.0f);
                using (Pen p = new Pen(IconAccent, 1.1f)) {
                    g.DrawLine(p, 4.6f, 5.0f, 4.6f, 8.0f);
                    g.DrawLine(p, 8.0f, 5.0f, 8.0f, 8.6f);
                    g.DrawLine(p, 11.4f, 5.0f, 11.4f, 8.0f);
                }
                break;
            }
            case IC_SOUND: {            // speaker with two waves
                PointF[] sp = new PointF[] {
                    new PointF(1.6f, 6.0f), new PointF(4.6f, 6.0f), new PointF(8.0f, 2.8f),
                    new PointF(8.0f, 13.2f), new PointF(4.6f, 10.0f), new PointF(1.6f, 10.0f) };
                using (SolidBrush b = new SolidBrush(IconAccent)) g.FillPolygon(b, sp);
                using (Pen p = new Pen(IconAccent, 1.5f)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawArc(p, 6.6f, 4.6f, 4.4f, 6.8f, -55f, 110f);
                    g.DrawArc(p, 6.6f, 2.4f, 8.0f, 11.2f, -55f, 110f);
                }
                break;
            }
            case IC_KEY: {              // a key
                using (Pen p = new Pen(IconAmber, 1.6f))
                    g.DrawEllipse(p, 1.6f, 1.6f, 6.2f, 6.2f);
                using (Pen p = new Pen(IconAmber, 1.7f)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, 6.8f, 6.8f, 14.2f, 14.2f);
                    g.DrawLine(p, 10.6f, 10.6f, 12.8f, 8.4f);
                    g.DrawLine(p, 12.6f, 12.6f, 14.4f, 10.8f);
                }
                break;
            }
            case IC_QUIT: {             // a cross
                using (Pen p = new Pen(IconRed, 1.9f)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, 3.6f, 3.6f, 12.4f, 12.4f);
                    g.DrawLine(p, 12.4f, 3.6f, 3.6f, 12.4f);
                }
                break;
            }
            case IC_MUTE: {             // speaker with a slash
                PointF[] sp = new PointF[] {
                    new PointF(1.6f, 6.0f), new PointF(4.6f, 6.0f), new PointF(8.0f, 2.8f),
                    new PointF(8.0f, 13.2f), new PointF(4.6f, 10.0f), new PointF(1.6f, 10.0f) };
                using (SolidBrush b = new SolidBrush(Color.FromArgb(255, 150, 158, 174))) g.FillPolygon(b, sp);
                using (Pen p = new Pen(IconRed, 1.8f)) {
                    p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                    g.DrawLine(p, 9.4f, 3.0f, 14.6f, 13.0f);
                }
                break;
            }
            }
        }
        return bmp;
    }

    void BuildMenu() {
        // Flat white surface, colour Emoji icons, section headers, our own blue tick.
        // ShowImageMargin stays ON because the icons live in that column.
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.ShowImageMargin = true;
        menu.ShowCheckMargin = false;          // the tick is drawn into the icon column
        menu.Font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Regular, GraphicsUnit.Point);
        _menuRenderer = new PetMenuRenderer();
        menu.Renderer = _menuRenderer;
        menu.Padding = new Padding(6, 6, 6, 6);
        _menu = menu;

        // ---- balance ----
        ToolStripMenuItem refresh = NewItem(IC_REFRESH, S_REFRESH);
        refresh.Click += delegate { _pollWant = 2; };
        _menu.Items.Add(refresh);

        _menu.Items.Add(new ToolStripSeparator());

        // ---- tests ----
        _menu.Items.Add(NewHeader("\u6D4B\u8BD5"));                   // test
        ToolStripMenuItem test = NewItem(IC_BOLT, S_TEST);
        test.Click += delegate { DemoCharge(StepYuan); };
        _menu.Items.Add(test);

        ToolStripMenuItem testTop = NewItem(IC_BOWL, S_TESTTOP);
        ToolStripMenuItem testTopGo = NewItem(IC_NONE, S_TESTTOPG);
        testTopGo.Click += delegate { TestTopUp(TestTopUpYuan); };
        testTop.DropDownItems.Add(testTopGo);
        testTop.DropDownItems.Add(new ToolStripSeparator());
        ToolStripMenuItem testTopCustom = NewItem(IC_NONE, S_CUSTOM);
        testTopCustom.Click += delegate { AskTopUp(); };
        testTop.DropDownItems.Add(testTopCustom);
        _menu.Items.Add(testTop);

        ToolStripMenuItem demoItem = NewItem(IC_CASCADE, S_HELP);
        double[] demos = new double[] { 0.05, 0.1, 0.2, 0.5, 1.0 };
        foreach (double d in demos) {
            double v = d;
            ToolStripMenuItem it = NewItem(IC_NONE, "-" + v.ToString("0.##", CultureInfo.InvariantCulture) +
                                               "  (" + CueCount(v) + " \u6B21)");
            it.Click += delegate { DemoCharge(v); };
            demoItem.DropDownItems.Add(it);
        }
        demoItem.DropDownItems.Add(new ToolStripSeparator());
        ToolStripMenuItem demoCustom = NewItem(IC_NONE, S_CUSTOM);
        demoCustom.Click += delegate { AskDemo(); };
        demoItem.DropDownItems.Add(demoCustom);
        _menu.Items.Add(demoItem);

        _menu.Items.Add(new ToolStripSeparator());

        // ---- display ----
        _menu.Items.Add(NewHeader("\u663E\u793A"));                   // display
        _sizeItem = NewItem(IC_SIZE, S_SIZE);
        // Presets are a radio group: the current one is marked with the tick the
        // renderer draws into the icon column, so no icon competes with it.
        for (int i = 0; i < SizeNames.Length; i++) {
            int idx = i;
            ToolStripMenuItem it = NewItem(IC_NONE, SizeNames[i] + "  " + PresetPxLabel(i));
            it.Click += delegate { SetSizePreset(idx); };
            _sizeItem.DropDownItems.Add(it);
        }
        _sizeItem.DropDownItems.Add(new ToolStripSeparator());
        ToolStripMenuItem sizeCustom = NewItem(IC_NONE, S_CUSTOM);
        sizeCustom.Click += delegate { AskPx(); };
        _sizeItem.DropDownItems.Add(sizeCustom);
        _menu.Items.Add(_sizeItem);

        // ---- sound ----
        _soundItem = NewItem(IC_SOUND, S_SOUND);
        _muteItem = NewItem(IC_NONE, S_SOUNDON);            // on/off toggle
        _muteItem.Click += delegate { SetSoundEnabled(!_soundEnabled); };
        _soundItem.DropDownItems.Add(_muteItem);
        _soundItem.DropDownItems.Add(new ToolStripSeparator());
        _soundItem.DropDownItems.Add(NewHeader(S_VOLT));    // level header
        for (int i = 0; i < VolumeSteps.Length; i++) {
            int v = VolumeSteps[i];
            ToolStripMenuItem it = NewItem(IC_NONE,
                v == 0 ? S_MUTE0 : v.ToString(CultureInfo.InvariantCulture) + " %");
            it.Click += delegate { SetVolumePercent(v); };
            _soundItem.DropDownItems.Add(it);
        }
        _soundItem.DropDownItems.Add(new ToolStripSeparator());
        ToolStripMenuItem volCustom = NewItem(IC_NONE, S_CUSTOM);
        volCustom.Click += delegate { AskVolume(); };
        _soundItem.DropDownItems.Add(volCustom);
        _menu.Items.Add(_soundItem);

        _menu.Items.Add(new ToolStripSeparator());

        // ---- system ----
        ToolStripMenuItem key = NewItem(IC_KEY, S_SETKEY);
        key.Click += delegate { AskKey(); };
        _menu.Items.Add(key);

        ToolStripMenuItem quit = NewItem(IC_QUIT, S_QUIT);
        quit.Click += delegate { Quit(); };
        _menu.Items.Add(quit);

        _menu.Opening += delegate { RefreshMenuChecks(); };
        StyleMenu(_menu.Items);
    }

    // Live sound settings, driven from the menu.
    void SetSoundEnabled(bool on) {
        _soundEnabled = on;
        _soundWanted = on;
        Log("sound " + (on ? "on" : "muted"));
        SaveState();
        _dirty = true;
    }

    void SetVolumePercent(int pct) {
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        _volume = pct;
        if (_sound != null) _sound.SetVolume(pct);
        if (_feedSound != null) _feedSound.SetVolume(pct);
        // 0 % IS mute, so the on/off row in the menu must follow it: otherwise
        // the menu would claim sound is on while the players are silent.
        bool on = pct > 0;
        _soundEnabled = on;
        _soundWanted = on;
        Log("volume set to " + pct + "%" + (on ? "" : " (muted)"));
        // A short cue so the new level is audible immediately.
        if (on) {
            if (_feedSound != null && !_feedSound.Failed) _feedSound.Play();
            else if (_sound != null) _sound.Play();
        }
        SaveState();
    }

    void AskVolume() {
        using (InputDialog d = new InputDialog(S_SOUND, S_VOLP, "%",
                                               _volume.ToString(CultureInfo.InvariantCulture))) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            int v;
            if (int.TryParse(d.Value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) && v >= 0 && v <= 100)
                SetVolumePercent(v);
            else
                Log("volume rejected: '" + d.Value + "'");
        }
    }

    // Give every item the same height, padding and tick, recursively. The stock
    // renderer leaves cramped rows and a chunky system tick that made the menu
    // look raw.
    void StyleMenu(ToolStripItemCollection items) {
        foreach (ToolStripItem it in items) {
            ToolStripMenuItem mi = it as ToolStripMenuItem;
            if (mi != null) {
                mi.Padding = new Padding(7, 4, 12, 4);
                mi.CheckOnClick = false;
                if (mi.DropDownItems.Count > 0) StyleMenu(mi.DropDownItems);
            }
        }
    }

    static string Yuan(double v) {
        return "-" + v.ToString("0.##", CultureInfo.InvariantCulture) + " \u00A5";
    }
    static string CueCount(double amount) {
        int n = (int)Math.Round(amount / StepYuan);
        return n < 1 ? "1" : n.ToString(CultureInfo.InvariantCulture);
    }
    static string CmLabel(double v) {
        return v.ToString("0.#", CultureInfo.InvariantCulture) + " cm";
    }
    // "454 px" for the menu, or "auto" before the window has been laid out.
    string PxLabel(int v) {
        return v > 0 ? (v.ToString(CultureInfo.InvariantCulture) + S_PXLBL) : "auto";
    }
    // Menu caption for a preset, showing the pixels the user will actually get.
    string PresetPxLabel(int i) {
        return "(" + PresetPx[i].ToString(CultureInfo.InvariantCulture) + S_PXLBL + ")";
    }

    // ToolStrip check marks are reset on every open, so push them here.
    void RefreshMenuChecks() {
        for (int i = 0; i < SizeNames.Length && i < _sizeItem.DropDownItems.Count; i++) {
            ToolStripMenuItem mi = _sizeItem.DropDownItems[i] as ToolStripMenuItem;
            if (mi != null) mi.Checked = (_sizePx == PresetPx[i]);
        }
        if (_muteItem != null) _muteItem.Checked = _soundEnabled;
        // The volume steps sit after [toggle, separator, header]; read the index
        // back from the array so inserting a header later cannot shift them.
        if (_soundItem != null) {
            int first = _soundItem.DropDownItems.IndexOf(_muteItem) + 3;
            for (int i = 0; i < VolumeSteps.Length; i++) {
                int idx = first + i;
                if (idx < 0 || idx >= _soundItem.DropDownItems.Count) break;
                ToolStripMenuItem mi = _soundItem.DropDownItems[idx] as ToolStripMenuItem;
                if (mi != null) mi.Checked = (_volume == VolumeSteps[i]);
            }
        }
    }

    // ------------------------------------------------------------- settings ---

    // Rehearsal: queue ceil(amount / 0.01) cues. They walk the printed number
    // down through _testOffset, leaving the real balance and the booking alone,
    // so a refresh afterwards simply restores the true value.
    void DemoCharge(double amount) {
        if (amount < StepYuan) amount = StepYuan;
        int cues = (int)Math.Round(amount / StepYuan);
        if (cues < 1) cues = 1;
        if (cues > 500) cues = 500;
        _demoLeft = cues;
        _demoAmount = StepYuan;
        Log("demo charge: " + Yuan(amount) + " -> " + cues + " cue(s), " +
            CueGapSec.ToString("0.#") + "s apart");
        _dirty = true;
    }

    void AskDemo() {
        using (InputDialog d = new InputDialog(S_HELPT, S_HELPP, "\u00A5", "0.1")) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            double v;
            if (double.TryParse(d.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v > 0)
                DemoCharge(v);
            else
                Log("demo amount rejected: '" + d.Value + "'");
        }
    }

    // ------------------------------------------------------- top-up testing ---
    // Menu-only rehearsal for the recharge animation, so testing it does not need
    // real money. It drives the SAME path a real top-up takes - the simulated
    // server balance really goes up by the amount - which is what makes the
    // rehearsal faithful: freeze, bowl, delivery, then the linear climb to the
    // new figure. "Refresh now" afterwards re-syncs to the live balance.
    void TestTopUp(double amount) {
        if (amount < StepYuan) amount = StepYuan;
        if (_rice != null && !_rice.Fed) {
            Log("test top-up ignored: a bowl is already waiting");
            return;
        }
        if (double.IsNaN(_realBal)) {
            Log("test top-up ignored: no balance reading yet");
            return;
        }
        double bal = Math.Round(_realBal + amount, 4);
        Log("test top-up: pretending the server went " +
            _realBal.ToString("0.00", CultureInfo.InvariantCulture) + " -> " +
            bal.ToString("0.00", CultureInfo.InvariantCulture) +
            " (local only; use refresh to re-sync)");
        ApplyBalance(bal, false);
    }

    void AskTopUp() {
        using (InputDialog d = new InputDialog(S_TOPT, S_TOPP, "\u00A5",
                                               TestTopUpYuan.ToString("0.##", CultureInfo.InvariantCulture))) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            double v;
            if (double.TryParse(d.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v > 0)
                TestTopUp(v);
            else
                Log("test top-up rejected: '" + d.Value + "'");
        }
    }

    // Presets are stored as pixels, so the widget is the same physical size
    // regardless of the monitor's DPI or scaling. _cm is cleared so the pixel
    // value is what Relayout uses.
    void SetSizePreset(int index) {
        if (index < 0 || index >= PresetPx.Length) return;
        SetPixelSize(PresetPx[index]);
        Log("size preset " + index + " (" + SizeNames[index] + ")");
    }

    void SetPixelSize(int px) {
        if (px < 40) px = 40;
        if (px > 2400) px = 2400;
        _sizePx = px;
        // Keep the legacy cm field consistent with the real monitor DPI, so a
        // downgrade (or the diag line) does not report a nonsense figure. A flat
        // 96 here made 454px claim to be 12cm.
        double dpiY = 96;
        try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) dpiY = g.DpiY; } catch { }
        if (dpiY < 72) dpiY = 96;
        _cm = Math.Round(px / dpiY * 2.54, 2);
        Relayout();
        SnapToCorner(true);               // keep it pinned to the corner
        SaveState();
        RenderToCanvas();
        PushLayer();
        Log("size set to " + px + " px");
    }

    void SetCm(double v) {
        if (v < 0.8) v = 0.8;
        if (v > 40) v = 40;
        _cm = v;
        _sizePx = 0;                      // legacy path: let the DPI decide again
        Relayout();
        SnapToCorner(true);               // keep it pinned to the corner
        SaveState();
        RenderToCanvas();
        PushLayer();
        Log("size set to " + CmLabel(v) + " -> " + _w + "x" + _h + " px");
    }

    void AskCm() { AskPx(); }

    void AskPx() {
        using (InputDialog d = new InputDialog(S_PXT, S_PXP, "px",
                                               (_sizePx > 0 ? _sizePx : _w).ToString(CultureInfo.InvariantCulture))) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            int v;
            if (int.TryParse(d.Value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) && v > 0)
                SetPixelSize(v);
            else
                Log("custom size rejected: '" + d.Value + "'");
        }
    }

    void AskKey() {
        using (InputDialog d = new InputDialog(S_KEYT, S_KEYP, "",
                                               _apiKey)) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            string k = d.Value;
            if (k.Length > 0 && k != _apiKey) {
                _apiKey = k;
                _isAccount = false;          // a manual key beats the account grant
                SaveKey(k);
                _pollWant = 2;
                Log("api key set manually (length " + k.Length + ")");
            }
        }
    }

    // ------------------------------------------------------------ geometry ---

    void Relayout() {
        // Physical size has to come from the real monitor DPI. If the process
        // could not be made DPI aware, Windows lies and reports 96, which would
        // shrink the widget on a scaled display - so fall back to the monitor's
        // actual DPI instead of trusting a 96 that was never real.
        double dpiY = 96;
        try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) dpiY = g.DpiY; } catch { }
        if (dpiY <= 96.5) {
            try {
                using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) {
                    IntPtr hdc = g.GetHdc();
                    int raw = Native.GetDeviceCaps(hdc, 90);          // LOGPIXELSY
                    g.ReleaseHdc(hdc);
                    if (raw > 0) dpiY = raw;
                }
            } catch { }
        }
        if (dpiY < 72) dpiY = 96;
        // A stored pixel edge wins: that is what the cup presets and the custom
        // entry record, and it is monitor-independent. _cm is only the fallback
        // for a state.ini written by an older build.
        int px = _sizePx > 0 ? _sizePx : (int)Math.Round(_cm / 2.54 * dpiY);
        if (px < 40) px = 40;
        // _w/_h describe the WIDGET (and the canvas/scale derived from it), NOT the
        // window. The window is created SCREEN-SIZED and keeps that size forever: any
        // resize re-composited the previous canvas onto the new window for two or
        // three frames, which put the girl at the window origin (the top-left of the
        // screen) for ~60ms every time a bowl dropped. The widget's place inside the
        // full-screen window is tracked by _offX/_offY instead.
        _w = px; _h = px;
        _winW = SystemInformation.VirtualScreen.Width;
        _winH = SystemInformation.VirtualScreen.Height;
        SyncWindowModeInternal();
        _scale = (double)_h / _flat.Height;

        int sw = Math.Max(2, (int)Math.Round(_flat.Width * _scale));
        int sh = Math.Max(2, (int)Math.Round(_flat.Height * _scale));
        Bitmap scaled = new Bitmap(sw, sh, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(scaled)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(_flat, new Rectangle(0, 0, sw, sh));
        }
        if (_sprNormal != null) _sprNormal.Dispose();
        if (_sprRed != null) _sprRed.Dispose();
        if (_canvas != null) _canvas.Dispose();

        _sprNormal = scaled;
        _sprRed = BuildRedLayer(scaled);
        // The canvas must match the WINDOW, not the widget: while a bowl is out the
        // window covers the screen and the widget is blitted in at _offX/_offY.
        _canvas = new Bitmap(_winW, _winH, PixelFormat.Format32bppArgb);

        // tablet screen quad in sprite pixels, from make_sprite.ps1 (min-area
        // rotated rectangle around the opaque black screen).
        // Current art: blue-haired maid, re-measured 2026-09-28. The panel moved
        // and grew versus the old artwork, so these MUST be refreshed whenever
        // sprite.png is rebuilt - otherwise the readout lands off the tablet.
        // ORDER MATTERS: index 0..3 must be TL, TR, BR, BL as seen on screen.
        // Caliper's own TL/TR/BR/BL labels follow its rotated frame and can come
        // out swapped when the panel is tilted the other way, which renders the
        // text upside down. Re-check the order by rendering --selftest.
        double[] qx = new double[] { 549.6, 949.7, 984.7, 584.6 };
        double[] qy = new double[] { 706.2, 642.0, 860.2, 924.3 };
        // Widget-relative coordinates. _offX/_offY are added when drawing, so these
        // stay the same whether the window is widget-sized or screen-sized.
        _fx = new double[4]; _fy = new double[4];
        for (int i = 0; i < 4; i++) { _fx[i] = qx[i] * _scale; _fy[i] = qy[i] * _scale; }

        _headX = (int)(sw * 0.50 + sh * 0.17);
        _headY = (int)(sh * 0.36);
        // one text line high, so a fast run of numbers cascades without overlapping
        _floaterStep = (float)Math.Max(18.0, 34.0 * _scale * 1.7);

        // The bowl is sized against the widget, and follows it when the size
        // preset changes. 0.44 of the edge, clamped so it stays draggable even at
        // the smallest preset.
        if (_riceFlat != null) {
            int rw = Math.Max(24, (int)Math.Round(_w * 0.44));
            if (_riceArt != null) _riceArt.Dispose();
            _riceArt = ScaleBitmap(_riceFlat, rw, rw);
            if (_rice != null) _rice.R = _riceArt.Width * 0.42;   // footprint radius
        }
        _hitMap = null;
        _dirty = true;
    }

    // Minecraft's feed-a-sheep heart, drawn on an 8x8 pixel grid so the blocky
    // look survives at any size. Palette taken from the reference screenshot:
    // dark red outline, mid red body, pale highlight.
    static Bitmap BuildHeartArt() {
        string[] rows = new string[] {
            ".DD..DD.",
            "DHHDDHHD",
            "DHHRRRHD",
            "DRRRRRRD",
            ".DRRRRD.",
            "..DRRD..",
            "...DD...",
            "........"
        };
        Bitmap bmp = new Bitmap(8, 8, PixelFormat.Format32bppArgb);
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 8; x++) {
                char c = rows[y][x];
                Color col = Color.FromArgb(0, 0, 0, 0);
                if (c == 'D') col = Color.FromArgb(255, 150, 24, 24);
                else if (c == 'H') col = Color.FromArgb(255, 246, 190, 190);
                else if (c == 'R') col = Color.FromArgb(255, 214, 43, 43);
                bmp.SetPixel(x, y, col);
            }
        }
        return bmp;
    }

    // Plain high-quality downscale, used for the props that are not the sprite.
    static Bitmap ScaleBitmap(Bitmap src, int w, int h) {
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        Bitmap dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(dst)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(src, new Rectangle(0, 0, w, h));
        }
        return dst;
    }

    // A recharge landed: freeze the readout and drop a bowl for it.
    // One top-up = one bowl. Several may be in flight; each carries its own Amount so
    // delivering it credits exactly that, and picking one up leaves the others alone.
    void StartCredit(double amount) {
        _creditPending = Math.Round(_creditPending + amount, 4);
        if (_riceArt == null) {                 // no art -> cannot be collected
            Log("top-up " + amount.ToString("0.00", CultureInfo.InvariantCulture) +
                " ignored: rice.png missing");
            return;
        }
        Rectangle vs = SystemInformation.VirtualScreen;
        Rice r = new Rice();
        r.R = _riceArt.Width * 0.42;
        r.Amount = amount;
        // Falls in from the TOP-RIGHT CORNER OF THE SCREEN and lands on the bottom
        // of the screen. X/Y are SCREEN pixels; DrawRiceArt converts them into this
        // window's canvas, which is why the bowl can start far outside the widget.
        // Extra bowls are nudged apart so a burst does not stack into one pile.
        r.X = vs.Right - r.R * 1.2 - _rices.Count * r.R * 0.5;
        r.Y = vs.Top - r.R * 1.2;
        r.VX = -120;                            // drifts left as it falls
        r.VY = 40;
        r.Rot = 0;
        // Falling in from above the top edge: a full-height drop, so the top tier.
        r.MaxBounces = BouncesForDrop(vs.Height);
        _rices.Add(r);
        _rice = r;                              // the newest one is the active one
        SyncWindowMode();                   // window must span the screen now
        Log("top-up " + amount.ToString("0.00", CultureInfo.InvariantCulture) +
            " -> rice bowl dropped from screen top-right (bowls now " + _rices.Count + ")");
        _dirty = true;
    }

    void SpawnHearts(int cx, int cy) {
        int n = 5 + _rng.Next(3);
        for (int i = 0; i < n; i++) {
            Floater f = new Floater();
            // feed => plain text, not a "-x.xx" charge
            f.Text = "";
            f.X = cx + _rng.Next(-_w / 8, _w / 8);
            f.Y = cy - _rng.Next(0, _h / 12);
            f.Hearts = true;
            // Sized as a fraction of the widget so the hearts keep their proportion to
            // the girl at every size preset. Was 0.030-0.050 (~14-23px at the default
            // 454px widget); now 0.055-0.085 (~25-39px), which reads clearly.
            f.HeartSize = (int)Math.Round(Math.Max(10.0, _w * (0.055 + 0.030 * _rng.NextDouble())));
            f.HeartPhase = _rng.NextDouble() * 6.283;
            f.Dur = 0.75 + _rng.NextDouble() * 0.35;
            f.Drift = (_rng.NextDouble() - 0.5) * 36.0;
            _hearts.Add(f);
        }
        _dirty = true;
    }

    // Delivered to the girl: hide the bowl, pop the hearts, and credit ITS top-up.
    //
    // One bowl = one recharge, so this credits the bowl's own Amount. The money is
    // applied HERE, in one go, at the instant of delivery: the printed number must
    // not move when a bowl spawns, falls, bounces or waits.
    void OnRiceFed(Rice bowl) {
        if (bowl == null) return;
        bowl.Fed = true;
        bowl.DieT = 0;
        bowl.Dragging = false;
        if (_rice == bowl) _rice = null;
        // Hearts are drawn straight into the canvas (see DrawHearts), so they need
        // SCREEN coordinates: _headX/_headY are widget-relative, and without the offset
        // the hearts landed in the canvas's top-left corner - off screen, so the feed
        // played its sound and paid out but showed no animation.
        SpawnHearts(_headX + _offX, (int)(_h * 0.20) + _offY);
        // Delivery cue: its own sound, not the hurt one. Falls back to the hit cue if
        // feed.mp3 is absent, so a stripped-down install still makes a noise.
        if (_soundWanted) {
            if (_feedSound != null && !_feedSound.Failed) _feedSound.Play();
            else if (_sound != null) _sound.Play();
        }
        // Credit this bowl's own amount, but never more than is actually owed; and
        // if the shortfall between the server figure and the readout is larger (a
        // rehearsal whose local bump a real poll rolled back), take that as a floor
        // so a delivered bowl can never pay out 0.00.
        bool haveFigures = !double.IsNaN(_realBal) && !double.IsNaN(_bookedBal);
        double shortfall = haveFigures ? Math.Round(_realBal - _bookedBal, 2) : 0;
        if (shortfall < 0) shortfall = 0;
        double owed = Math.Max(_creditPending, shortfall);
        double gain = Math.Min(bowl.Amount, owed);
        if (gain <= 1e-9) gain = owed;          // bowl amount unknown -> settle the lot
        if (gain > 1e-9) {
            // ApplyCredit moves _bookedAt as well, so the next poll cannot read the
            // credited amount as fresh debt.
            ApplyCredit(gain);
            Floater fl = new Floater();
            fl.Text = "+" + gain.ToString("0.00", CultureInfo.InvariantCulture);
            fl.X = _headX - (int)(_w * 0.06);
            fl.Y = _headY - (int)Math.Round(2 * _floaterStep);
            _floaters.Add(fl);
        } else {
            gain = 0;
        }
        bowl.FedAmount = gain;
        // Collected means collected: drop the rehearsal offset. Without clearing
        // _testOffset, rehearsals ("test one charge") started while the bowl was
        // waiting subtracted themselves from the freshly credited money, so the
        // number looked like it had not gone up.
        //
        // Deliberately NO re-alignment of _bookedBal to _realBal here: ApplyCredit
        // has already moved the printed figure by the credited amount, and forcing
        // it onto _realBal would throw that credit away whenever the server figure
        // is lower than the readout (exactly what happens to a rehearsal whose local
        // bump the next real poll rolled back).
        _testOffset = 0;
        _creditPending = Math.Round(Math.Max(0, _creditPending - gain), 4);
        // Hold off the spending animation for a moment so the hearts are actually
        // seen. Applies to both kinds of bowl: once the cloud figure is read again a
        // real recharge is re-booked as debt just like a rehearsal.
        _cueGrace = FeedGraceSec;
        // One line that says everything needed to debug "fed but nothing changed":
        // what was owed, what the books looked like, and where the readout landed.
        Log("rice fed -> credited " + gain.ToString("0.00", CultureInfo.InvariantCulture) +
            " of " + bowl.Amount.ToString("0.00", CultureInfo.InvariantCulture) +
            " pendingLeft=" + _creditPending.ToString("0.0000", CultureInfo.InvariantCulture) +
            " real=" + _realBal.ToString("0.0000", CultureInfo.InvariantCulture) +
            " bookedBal=" + _bookedBal.ToString("0.0000", CultureInfo.InvariantCulture) +
            " bookedAt=" + _bookedAt.ToString("0.0000", CultureInfo.InvariantCulture) +
            " printed=" + DrawnText + " bowls=" + _rices.Count +
            " grace=" + FeedGraceSec.ToString("0.#", CultureInfo.InvariantCulture) + "s");
        _dirty = true;
    }

    // -------------------------------------------------------- rice physics --

    // The bowls move in SCREEN coordinates so they can fall from the real right edge
    // of the monitor and be dragged across the desktop, even though they are painted
    // inside this small widget-shaped window.
    void UpdateRice(double dt) {
        if (dt > 0.10) dt = 0.10;
        Rectangle vs = SystemInformation.VirtualScreen;
        bool hadBowls = _rices.Count > 0;
        for (int i = _rices.Count - 1; i >= 0; i--) {
            Rice r = _rices[i];
            if (r.Fed) {
                r.DieT += dt;
                if (r.DieT > 0.14) {
                    _rices.RemoveAt(i); if (_rice == r) _rice = null;
                    Log("bowl removed (fed) bowlsLeft=" + _rices.Count);
                }
                continue;
            }
            if (r.SquishT < r.SquishDur) r.SquishT += dt;
            if (r.Dragging) {
                r.Squish = 0;
                r.VX = 0; r.VY = 0;
            } else {
                // Always integrate: a bowl resting on the floor is just a bowl whose
                // velocity keeps being cancelled by the floor, and keeping gravity on
                // is what makes a re-thrown bowl behave like a dropped one.
                r.VY += RiceGravity * dt;
                r.VX *= (1.0 - 0.55 * dt);       // air drag, mostly lateral
                r.X += r.VX * dt;
                r.Y += r.VY * dt;

                double floor = vs.Bottom - r.R;      // the SCREEN floor
                if (!r.LandedLogged && Math.Abs(r.VY) < 200 && r.Y > floor - 400) {
                    r.LandedLogged = true;
                    Log("bowl landing: y=" + r.Y.ToString("0") + " floor=" + floor.ToString("0") +
                        " bottomOnScreen=" + (r.Y + r.R - _offY).ToString("0") +
                        " vsBottom=" + vs.Bottom + " vsTop=" + vs.Top + " R=" + r.R.ToString("0") +
                        " offX=" + _offX + " offY=" + _offY +
                        " canvasH=" + (_canvas == null ? 0 : _canvas.Height) +
                        " winTop=" + Top + " clientH=" + ClientSize.Height + " widgetH=" + _h);
                }
                if (r.Y >= floor) {
                    r.Y = floor;
                    double impact = r.VY;
                    r.VX *= 0.72;
                    r.VY = -impact * RiceRestitution;
                    // Bounce height follows the drop, so the first fall off the top of
                    // the screen bounces properly instead of dying instantly.
                    if (impact > 90 && r.Bounces < r.MaxBounces) {
                        r.Bounces++;
                        r.Squish = 1.0;              // squash on impact
                        r.SquishT = 0;
                        r.SquishDur = 0.40;          // slower settle = softer look
                    }
                    if (r.Bounces >= r.MaxBounces || Math.Abs(r.VY) < 45) {
                        r.VY = 0; r.VX = 0; r.Grounded = true;
                        r.Rot = 0;
                    } else {
                        r.Grounded = false;
                    }
                } else {
                    r.Grounded = false;
                }
                if (r.X < vs.Left + r.R) { r.X = vs.Left + r.R; r.VX = Math.Abs(r.VX) * 0.5; }
                if (r.X > vs.Right - r.R) { r.X = vs.Right - r.R; r.VX = -Math.Abs(r.VX) * 0.5; }
                if (r.Y < vs.Top + r.R) { r.Y = vs.Top + r.R; if (r.VY < 0) r.VY = 0; }
            }
            // "Q-bounce": squash at impact, a counter-stretch right after, then
            // settle. Slower and larger than the first attempt, which snapped back in
            // ~0.3s and looked rigid.
            if (r.SquishT < r.SquishDur) {
                double u = r.SquishT / r.SquishDur;
                r.Squish = Math.Cos(u * Math.PI * 2.2) * (1.0 - u) * 0.52;
            } else {
                r.Squish = 0;
            }
        }
        // Bowl-versus-bowl collision, after every bowl has been integrated so the
        // pairs all see the same frame. Without this, two bowls dropped together
        // stack exactly on top of each other. Treated as circles of radius R.
        for (int a = 0; a < _rices.Count; a++) {
            Rice ra = _rices[a];
            if (ra.Fed) continue;
            for (int b = a + 1; b < _rices.Count; b++) {
                Rice rb = _rices[b];
                if (rb.Fed) continue;
                double dx = rb.X - ra.X, dy = rb.Y - ra.Y;
                double minD = ra.R + rb.R;
                double d2 = dx * dx + dy * dy;
                if (d2 >= minD * minD) continue;
                double d = Math.Sqrt(d2);
                if (d < 0.001) {                    // dead centre: split them apart
                    dx = 1; dy = 0; d = 1;
                }
                double nx = dx / d, ny = dy / d;
                double push = (minD - d) * 0.5;     // each moves half the overlap
                // A bowl being dragged keeps its position; the other one yields.
                bool aFixed = ra.Dragging, bFixed = rb.Dragging;
                double aw = aFixed ? 0 : (bFixed ? 1 : 0.5);
                double bw = bFixed ? 0 : (aFixed ? 1 : 0.5);
                ra.X -= nx * push * 2 * aw; ra.Y -= ny * push * 2 * aw;
                rb.X += nx * push * 2 * bw; rb.Y += ny * push * 2 * bw;
                // Swap the approaching part of the velocity, damped.
                double va = ra.VX * nx + ra.VY * ny;
                double vb = rb.VX * nx + rb.VY * ny;
                if (va - vb > 0 && !aFixed && !bFixed) {
                    double imp = (va - vb) * 0.55;
                    ra.VX -= imp * nx; ra.VY -= imp * ny;
                    rb.VX += imp * nx; rb.VY += imp * ny;
                }
            }
        }
        if (hadBowls && _rices.Count == 0) SyncWindowMode();

        for (int i = _hearts.Count - 1; i >= 0; i--) {
            _hearts[i].T += dt;
            if (_hearts[i].Done) _hearts.RemoveAt(i);
        }

        // NOTE: there is deliberately NO recovery/climb code here any more. The
        // top-up is credited entirely inside OnRiceFed(), at the instant of delivery.
        // An earlier version interpolated the number over 0.9s from this loop, which
        // meant the value could start moving on its own the moment a bowl appeared.
    }

    // Position the widget inside the (permanently screen-sized) window.
    //
    // The window size NEVER changes - see ApplySize. It is always the whole virtual
    // screen, and the widget lives at _offX/_offY inside it. That is what removes the
    // flash: a resize made Windows composite the previous canvas onto the new window
    // for a couple of frames, so the girl appeared at the window origin (screen
    // top-left) for ~60ms each time a bowl dropped.
    void SyncWindowModeInternal() {
        Rectangle vs = SystemInformation.VirtualScreen;
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        _winW = vs.Width; _winH = vs.Height;
        // Keep the window pinned to the virtual screen's origin: the canvas is indexed
        // in screen coordinates minus _offX/_offY, so the window origin must stay put.
        if (Left != vs.Left || Top != vs.Top ||
            ClientSize.Width != _winW || ClientSize.Height != _winH) {
            SetBounds(vs.Left, vs.Top, _winW, _winH);
        }
        if (_rices.Count > 0) {
            // A bowl is out: keep the widget exactly where it is, so nothing jumps.
            if (_offX == 0 && _offY == 0) {
                _offX = wa.Left - vs.Left;
                _offY = Math.Max(0, wa.Bottom - vs.Top - _h);
            }
        } else {
            // No bowl: the widget sits on the work-area floor, bottom-left.
            _offX = wa.Left - vs.Left;
            _offY = Math.Max(0, wa.Bottom - vs.Top - _h);
        }
        _fullScreen = _rices.Count > 0;
    }

    void SyncWindowMode() {
        int oldW = _winW, oldH = _winH;
        SyncWindowModeInternal();
        if (_winW != oldW || _winH != oldH) {
            int sw = Math.Max(2, (int)Math.Round(_flat.Width * _scale));
            int sh = Math.Max(2, (int)Math.Round(_flat.Height * _scale));
            IgnoreSizeDpiScale(sw, sh);
            // Repaint and push in the same step as the resize. Without this the
            // previous canvas kept being composited onto the new, screen-sized window
            // for a frame or two: the girl appeared at the window origin (screen
            // top-left), then at her old spot - the flash seen when a bowl dropped.
            if (Handle != IntPtr.Zero) { RenderToCanvas(); PushLayer(); }
        }
    }

    // Rebuild the scaled sprite + canvas for the current widget size (no window
    // geometry changes: ApplySize already dealt with that).
    void IgnoreSizeDpiScale(int sw, int sh) {
        Bitmap scaled = new Bitmap(sw, sh, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(scaled)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(_flat, new Rectangle(0, 0, sw, sh));
        }
        if (_sprNormal != null) _sprNormal.Dispose();
        if (_sprRed != null) _sprRed.Dispose();
        if (_canvas != null) _canvas.Dispose();
        _sprNormal = scaled;
        _sprRed = BuildRedLayer(scaled);
        _canvas = new Bitmap(_winW, _winH, PixelFormat.Format32bppArgb);
        _hitMap = null;
        _charHitMap = null;
        _girlStampedOn = null;
        _girlStamped = false;
        _lastCanvas = null;              // forces a full widget repaint
        _forceFullFill = true;           // and a full refresh of the push buffer
        _dirty = true;
    }

    void ApplyCredit(double delta) {
        if (Math.Abs(delta) < 1e-9) return;
        if (!double.IsNaN(_bookedBal)) _bookedBal = Math.Round(_bookedBal + delta, 4);
        if (!double.IsNaN(_bookedAt))  _bookedAt  = Math.Round(_bookedAt  + delta, 4);
    }

    // A drag release decides the outcome: dropped on the girl -> collected,
    // anywhere else -> the bowl simply stays where it was put.
    bool RiceOnGirl(Rice bowl) {
        // Bowls are in SCREEN pixels and _charHitMap is indexed in CANVAS coordinates.
        // The window origin IS the screen origin, so canvas == screen and _offX/_offY
        // must NOT be subtracted here (they only place the widget inside the canvas).
        if (bowl == null || _charHitMap == null || _riceArt == null) return false;
        // The map and the canvas are kept the same size; if they ever disagree
        // (a stale map from before a resize) just refuse rather than index wildly.
        if (_canvas == null || _charHitMap.Length != _canvas.Width * _canvas.Height) return false;
        int cw = _canvas.Width, ch = _canvas.Height;
        double hw = _riceArt.Width / 2.0;
        int x0 = (int)Math.Round(bowl.X - hw), x1 = (int)Math.Round(bowl.X + hw);
        int y0 = (int)Math.Round(bowl.Y - hw), y1 = (int)Math.Round(bowl.Y + hw);
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > cw - 1) x1 = cw - 1;
        if (y1 > ch - 1) y1 = ch - 1;
        // Contact = the bowl's FOOTPRINT touching the girl, not a wide circle around
        // its centre. hw*0.62 reached far beyond the bowl's base, so a bowl merely
        // waved near her triggered delivery - the bowl "vanished on touch".
        double r = hw * 0.45, r2 = r * r;
        int need = Math.Max(3, (int)Math.Round(r * 0.35));
        int hit = 0;
        for (int y = y0; y <= y1; y++) {
            int row = y * cw;
            double dy = y - bowl.Y;
            for (int x = x0; x <= x1; x++) {
                double dx = x - bowl.X;
                if (dx * dx + dy * dy > r2) continue;
                if (_charHitMap[row + x] > 8) { hit++; if (hit >= need) return true; }
            }
        }
        return false;
    }

    // Draws every bowl that is out. GDI+ scaled/rotated drawing, layered on top of
    // the sprite. The squash is anchored at each bowl's base so it always sits on
    // the floor. r.X / r.Y are SCREEN pixels; they become canvas pixels here.
    void DrawRice(Graphics g) {
        if (_riceArt == null) return;
        for (int i = 0; i < _rices.Count; i++) {
            Rice r = _rices[i];
            if (r.Fed) {
                double e = 1.0 - r.DieT / 0.14;
                if (e <= 0) continue;
                DrawRiceArt(g, r, e);
            } else {
                DrawRiceArt(g, r, 1.0);
            }
        }
    }

    void DrawRiceArt(Graphics g, Rice r, double opacity) {
        double sq = r.Squish;
        double sw = 1.0 + sq * 0.75;
        double sh = 1.0 - sq * 0.75;
        if (sw < 0.15) sw = 0.15;
        if (sh < 0.15) sh = 0.15;
        float h = _riceArt.Height;
        // Bowls are already in SCREEN pixels and the window origin is the screen
        // origin, so canvas == screen here. Subtracting _offY was wrong: that is only
        // the WIDGET's place inside the canvas, and applying it to bowls drew them
        // ~1000px too high (they looked like they stopped a third of the way down).
        float cx = (float)r.X;
        float baseY = (float)(r.Y + r.R);            // the bowl's bottom edge
        var save = g.Save();
        try {
            g.TranslateTransform(cx, baseY);
            if (r.Rot != 0) g.RotateTransform((float)(r.Rot * 180.0 / Math.PI));
            g.ScaleTransform((float)sw, (float)sh);
            if (opacity >= 0.999) g.DrawImage(_riceArt, -h / 2f, -h);
            else {
                // Fading out: wrap the art in an ImageAttributes alpha matrix
                // rather than fiddling with the locked canvas buffer.
                RectangleF dst = new RectangleF(-h / 2f, -h, h, h);
                ColorMatrix cm = new ColorMatrix();
                cm.Matrix33 = (float)Math.Max(0.0, opacity);
                using (ImageAttributes ia = new ImageAttributes()) {
                    ia.SetColorMatrix(cm);
                    g.DrawImage(_riceArt, Rectangle.Round(dst), 0f, 0f,
                                (float)_riceArt.Width, (float)_riceArt.Height,
                                GraphicsUnit.Pixel, ia);
                }
            }
        } finally {
            g.Restore(save);
        }
    }

    // Girl-only silhouette for the delivery test. Redraws just the sprite into a
    // scratch buffer, so it can never contain the bowl (matching the bowl against
    // itself is what once made the balance climb the moment the bowl appeared).
    void SnapshotGirl(int ox, int oy) { StampGirlAlpha(ox, oy); }

    // Stamp the cached silhouette into the hit map at a canvas position.
    void StampGirlAlpha(int ox, int oy) {
        // Sized to the CANVAS, not the widget. While a bowl is out the canvas is
        // the whole screen and the girl is drawn at _offY, so a _w*_h map was both
        // too small and indexed in the wrong space - which is why the bowl stopped
        // being accepted on her (the delivery test never found a single girl pixel).
        int cw = _canvas == null ? _w : _canvas.Width;
        int ch = _canvas == null ? _h : _canvas.Height;
        if (_charHitMap == null || _charHitMap.Length != cw * ch) {
            _charHitMap = new byte[cw * ch];
            _girlStampedOn = null;             // a fresh array has nothing to erase
        }
        if (_sprNormal == null) return;

        // The girl's silhouette is just the sprite's alpha, which only changes when
        // the sprite is rebuilt - so it is cached, not re-blitted. The old version
        // allocated a canvas-sized bitmap, blitted the sprite into it and scanned
        // every canvas pixel (2560*1600) on EVERY frame while a bowl was out: 12 ms
        // per frame, which is what made a falling bowl stutter when the girl moved.
        if (_girlAlpha == null || _girlAlphaW != _sprNormal.Width || _girlAlphaH != _sprNormal.Height) {
            _girlAlphaW = _sprNormal.Width;
            _girlAlphaH = _sprNormal.Height;
            _girlAlpha = new byte[_girlAlphaW * _girlAlphaH];
            Buf sb = new Buf(_sprNormal);
            try {
                byte[] sp = sb.P;
                for (int y = 0; y < _girlAlphaH; y++) {
                    int srow = y * sb.Stride, drow = y * _girlAlphaW;
                    for (int x = 0; x < _girlAlphaW; x++) _girlAlpha[drow + x] = sp[srow + x * 4 + 3];
                }
            } finally { sb.Dispose(); }
            _girlStamped = false;
        }

        // Erase where she was stamped last frame (only if it went into THIS array:
        // a reallocated map is already zeroed).
        if (_girlStamped && object.ReferenceEquals(_girlStampedOn, _charHitMap))
            ClearRect(_charHitMap, cw, _girlStampX, _girlStampY, _girlAlphaW, _girlAlphaH);

        for (int y = 0; y < _girlAlphaH; y++) {
            int ty = oy + y;
            if (ty < 0 || ty >= ch) continue;
            int sx = 0, len = _girlAlphaW, x0 = ox;
            if (x0 < 0) { sx = -x0; len += x0; x0 = 0; }
            if (x0 + len > cw) len = cw - x0;
            if (len <= 0) continue;
            Array.Copy(_girlAlpha, y * _girlAlphaW + sx, _charHitMap, ty * cw + x0, len);
        }
        _girlStampX = ox; _girlStampY = oy;
        _girlStamped = true;
        _girlStampedOn = _charHitMap;
    }

    static void ClearRect(byte[] map, int stride, int x, int y, int w, int h) {
        for (int yy = 0; yy < h; yy++) {
            int ty = y + yy;
            if (ty < 0) continue;
            long rowStart = (long)ty * stride;
            if (rowStart >= map.Length) break;
            int x0 = Math.Max(0, x), x1 = Math.Min(stride, x + w);
            if (x1 <= x0) continue;
            Array.Clear(map, (int)rowStart + x0, x1 - x0);
        }
    }

    // The small pixel hearts above the girl's head.
    void DrawHearts(Graphics g) {
        if (_heartArt == null) return;
        for (int i = 0; i < _hearts.Count; i++) {
            Floater f = _hearts[i];
            double u = f.T / f.Dur;
            if (u < 0 || u > 1) continue;
            double a = u < 0.15 ? u / 0.15 : 1.0 - (u - 0.15) / 0.85;
            if (a <= 0) continue;
            double rise = 46.0 * u;
            double wob = Math.Sin(f.HeartPhase + u * 7.0) * 6.0;
            int s = f.HeartSize;
            g.DrawImage(_heartArt,
                new Rectangle((int)Math.Round(f.X + f.Drift * u + wob),
                              (int)Math.Round(f.Y - rise), s, s));
        }
    }

    // Flat red copy of the art for the hurt flash (alpha preserved).
    static Bitmap BuildRedLayer(Bitmap src) {
        Bitmap dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        Buf s = new Buf(src);
        try {
            Buf d = new Buf(dst);
            try {
                for (int y = 0; y < s.H; y++) {
                    for (int x = 0; x < s.W; x++) {
                        int si = y * s.Stride + x * 4, di = y * d.Stride + x * 4;
                        d.P[di]     = 34;
                        d.P[di + 1] = 48;
                        d.P[di + 2] = 255;
                        d.P[di + 3] = s.P[si + 3];
                    }
                }
                d.Flush();
            } finally { d.Dispose(); }
        } finally { s.Dispose(); }
        return dst;
    }

    // Snap the WIDGET back to the bottom-left corner of the work area. The window no
    // longer moves (it is permanently screen-sized), so this animates _offX/_offY.
    void SnapToCorner(bool immediate) {
        Rectangle vs = SystemInformation.VirtualScreen;
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Point target = new Point(wa.Left - vs.Left, Math.Max(0, wa.Bottom - vs.Top - _h));
        if (immediate) {
            _offX = target.X; _offY = target.Y;
            _snapping = false;
            return;
        }
        // Do NOT guard this on "a bowl is out". That guard is a leftover from the days
        // when the window itself was resized: snapping then meant shrinking a
        // screen-sized window, which killed the fall. The window is permanently
        // screen-sized now and bowls live in SCREEN coordinates, so moving the widget
        // cannot disturb them. Keeping the guard meant that after a bowl dropped, the
        // girl stayed wherever she was released (user-reported 2026-09-28).
        // RunSnapBackTest() now pins both halves: she flies home WITH a bowl out, and
        // that bowl does not move.
        _snapFrom = new Point(_offX, _offY);
        _snapTo = target;
        _snapT = 0;
        _snapping = true;
    }

    // --------------------------------------------------------------- state ---

    string StatePath { get { return Path.Combine(_baseDir, "state.ini"); } }
    string KeyPath { get { return Path.Combine(_baseDir, "apikey.txt"); } }

    void ReadState() {
        try {
            bool volumeRead = false;
            if (!File.Exists(StatePath)) return;
            foreach (string line in File.ReadAllLines(StatePath)) {
                int i = line.IndexOf('=');
                if (i <= 0) continue;
                string k = line.Substring(0, i).Trim(), v = line.Substring(i + 1).Trim();
                double d;
                int n;
                if (k == "px" && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) && n >= 40)
                    _sizePx = n;                       // presets / custom entry
                else if (k == "cm" && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d) && d >= 0.8)
                    _cm = d;                           // legacy, only used if px is absent
                else if (k == "volume" && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) && n >= 0 && n <= 100) {
                    _volume = n; volumeRead = true;
                } else if (k == "sound" && (v == "0" || v == "1")) {
                    _soundEnabled = v == "1"; _soundWanted = _soundEnabled;
                }
            }
            // Push the stored level into the pools that were built earlier. No test
            // cue here - ReadState runs during start-up and should stay silent.
            if (volumeRead) {
                if (_sound != null) _sound.SetVolume(_volume);
                if (_feedSound != null) _feedSound.SetVolume(_volume);
            }
        } catch { }
    }

    void SaveState() {
        // A diagnostic run must never rewrite the settings the user is living
        // with: --simchain walks the size presets and the sound test moves the
        // volume, and both used to write state.ini on the way through.
        if (_noSave) { Log("state write skipped (diagnostic run)"); return; }
        try {
            // px is what the cup presets and the custom entry use; cm stays so an
            // older build could still read the file. volume/sound are live settings.
            File.WriteAllText(StatePath,
                "px=" + _sizePx.ToString(CultureInfo.InvariantCulture) + "\r\n" +
                "cm=" + _cm.ToString("0.##", CultureInfo.InvariantCulture) + "\r\n" +
                "volume=" + _volume.ToString(CultureInfo.InvariantCulture) + "\r\n" +
                "sound=" + (_soundEnabled ? "1" : "0") + "\r\n",
                Encoding.ASCII);
        } catch { }
    }

    void SaveKey(string k) {
        try { File.WriteAllText(KeyPath, k, Encoding.ASCII); } catch { }
    }

    // -------------------------------------------------------------- window ---

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        _dirty = true;
        RenderToCanvas();
        PushLayer();
    }

    // A persistent 32bpp DIB the size of the canvas, plus the DC that holds it.
    // Building one of these per frame (Bitmap.GetHbitmap) allocated and copied
    // 16 MB every frame; a BitBlt into a DIB that already exists is far cheaper.
    IntPtr _memDc, _memBmp, _memOld, _memBits;
    int _memW, _memH;
    byte[] _rowScratch;
    bool _forceFullFill;
    void EnsureMemSurface(int w, int h) {
        if (_memBmp != IntPtr.Zero && _memW == w && _memH == h) return;
        ReleaseMemSurface();
        IntPtr screenDc = Native.GetDC(IntPtr.Zero);
        _memDc = Native.CreateCompatibleDC(screenDc);
        Native.BITMAPINFO bi = new Native.BITMAPINFO();
        bi.bmiHeader.biSize = Marshal.SizeOf(typeof(Native.BITMAPINFOHEADER));
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;                 // top-down: row 0 is the top
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = 0;             // BI_RGB
        _memBmp = Native.CreateDIBSection(screenDc, ref bi, 0, out _memBits, IntPtr.Zero, 0);
        if (_memBmp != IntPtr.Zero) _memOld = Native.SelectObject(_memDc, _memBmp);
        Native.ReleaseDC(IntPtr.Zero, screenDc);
        _memW = w; _memH = h;
        _forceFullFill = true;                      // a brand new DIB holds nothing
    }
    void ReleaseMemSurface() {
        if (_memDc != IntPtr.Zero) {
            if (_memOld != IntPtr.Zero) Native.SelectObject(_memDc, _memOld);
            if (_memBmp != IntPtr.Zero) Native.DeleteObject(_memBmp);
            Native.DeleteDC(_memDc);
        }
        _memDc = _memBmp = _memOld = _memBits = IntPtr.Zero;
        _memW = _memH = 0;
    }

    // Copy a canvas rectangle into the DIB, converting straight ARGB (what
    // LockBits hands out) to the premultiplied form UpdateLayeredWindow expects.
    // GetHbitmap does exactly this conversion - measured: straight [255,0,0,128]
    // comes back from it as [128,0,0,128] - but it does it by building a brand new
    // 16 MB HBITMAP on every frame, which was 6 ms of the frame budget.
    void FillDib(Rectangle r) {
        r = Rectangle.Intersect(r, CanvasRect());
        int rw = r.Width, rh = r.Height;
        if (rw <= 0 || rh <= 0) return;
        if (_rowScratch == null || _rowScratch.Length < rw * 4) _rowScratch = new byte[rw * 4];
        Buf cb = new Buf(_canvas, r);
        try {
            byte[] sp = cb.P;
            int stride = cb.Stride;
            int dibStride = _memW * 4;
            for (int y = 0; y < rh; y++) {
                int so = y * stride;
                for (int x = 0; x < rw; x++) {
                    int i = so + x * 4, o = x * 4;
                    int a = sp[i + 3];
                    if (a == 255) {
                        _rowScratch[o] = sp[i]; _rowScratch[o + 1] = sp[i + 1];
                        _rowScratch[o + 2] = sp[i + 2]; _rowScratch[o + 3] = 255;
                    } else {
                        _rowScratch[o]     = (byte)((sp[i]     * a + 127) / 255);
                        _rowScratch[o + 1] = (byte)((sp[i + 1] * a + 127) / 255);
                        _rowScratch[o + 2] = (byte)((sp[i + 2] * a + 127) / 255);
                        _rowScratch[o + 3] = (byte)a;
                    }
                }
                Marshal.Copy(_rowScratch, 0, IntPtr.Add(_memBits, (r.Top + y) * dibStride + r.Left * 4), rw * 4);
            }
        } finally { cb.Dispose(); }
    }

    void PushLayer() {
        if (_canvas == null || Handle == IntPtr.Zero) return;
        Rectangle dr = _dirtyRect;
        bool haveDirty = _forceFullFill || (!dr.IsEmpty && dr.Width > 0 && dr.Height > 0);
        // Nothing changed, so the screen already shows it: the caller re-renders on
        // every animation frame, and a frame that repainted nothing does not need a
        // 16 MB composite.
        if (!haveDirty) return;
        if (_ulwBlt) {
            EnsureMemSurface(_canvas.Width, _canvas.Height);
            if (_memBmp != IntPtr.Zero) {
                // Keep the persistent DIB in step with the canvas by copying only the
                // part that changed, then hand the whole window over. The DIB is
                // complete at all times, so a full composite is always correct.
                //
                // prcDirty (UpdateLayeredWindowIndirect) would in principle let the
                // compositor touch just this rectangle, but measured here it is
                // ignored: the call still composites the entire window, so a DIB that
                // was only partly refreshed came back as ghosting of whatever used to
                // be in the untouched part. `--ulwcheck` is what caught that.
                FillDib(_forceFullFill ? CanvasRect() : dr);
                _forceFullFill = false;
                if (PushViaDib()) return;
            }
            _ulwBlt = false;                        // DIB route unusable: use the old one
        }
        PushViaHBitmap();
    }

    // The fast path: the image is already in the DIB, so this is one composite - no
    // 16 MB HBITMAP is built per frame.
    bool PushViaDib() {
        IntPtr screenDc = Native.GetDC(IntPtr.Zero);
        try {
            Native.SIZE size = new Native.SIZE(); size.cx = _canvas.Width; size.cy = _canvas.Height;
            Native.POINT src = new Native.POINT(); src.X = 0; src.Y = 0;
            Native.POINT dst = new Native.POINT(); dst.X = Left; dst.Y = Top;
            Native.BLENDFUNCTION bf = new Native.BLENDFUNCTION();
            bf.BlendOp = Native.AC_SRC_OVER; bf.BlendFlags = 0;
            bf.SourceConstantAlpha = 255; bf.AlphaFormat = Native.AC_SRC_ALPHA;
            return Native.UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, _memDc,
                                              ref src, 0, ref bf, Native.ULW_ALPHA);
        } finally {
            Native.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    // The original path, kept as the fallback: build an HBITMAP for the whole canvas
    // and let UpdateLayeredWindow recomposite all of it.
    void PushViaHBitmap() {
        IntPtr screenDc = Native.GetDC(IntPtr.Zero);
        IntPtr memDc = Native.CreateCompatibleDC(screenDc);
        IntPtr hBmp = IntPtr.Zero, old = IntPtr.Zero;
        try {
            hBmp = _canvas.GetHbitmap(Color.FromArgb(0));
            old = Native.SelectObject(memDc, hBmp);
            Native.SIZE size = new Native.SIZE(); size.cx = _canvas.Width; size.cy = _canvas.Height;
            Native.POINT src = new Native.POINT(); src.X = 0; src.Y = 0;
            Native.POINT dst = new Native.POINT(); dst.X = Left; dst.Y = Top;
            Native.BLENDFUNCTION bf = new Native.BLENDFUNCTION();
            bf.BlendOp = Native.AC_SRC_OVER; bf.BlendFlags = 0;
            bf.SourceConstantAlpha = 255; bf.AlphaFormat = Native.AC_SRC_ALPHA;
            Native.UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, Native.ULW_ALPHA);
        } finally {
            if (old != IntPtr.Zero) Native.SelectObject(memDc, old);
            if (hBmp != IntPtr.Zero) Native.DeleteObject(hBmp);
            Native.DeleteDC(memDc);
            Native.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    // Is the GIRL under this client point? A transparent pixel here means the
    // mouse must reach whatever is underneath.
    bool GirlPixelSolid(int cx, int cy) {
        byte[] map = _hitMap;
        if (map != null && cx >= 0 && cy >= 0 && cx < _hitW && cy < _hitH) return map[cy * _hitW + cx] > 8;
        return false;
    }

    // Is any BOWL under this client point? Bowls use SCREEN coordinates while the
    // event is in client pixels, hence the +Left/+Top. The box is the art's own
    // bounds, NOT a screen-wide one - a screen-space box made every pixel of the
    // desktop "solid" and ate every click. Iterates every bowl so each one can be
    // picked up, and returns which one so the grab can bind to it.
    Rice BowlAt(int cx, int cy) {
        if (_riceArt == null) return null;
        double hw = _riceArt.Width / 2.0;
        // Client coords == screen coords (window origin is the screen origin) and the
        // bowl is in screen pixels, so no offset conversion is needed here.
        double r = hw * 0.72, r2 = r * r;
        for (int i = _rices.Count - 1; i >= 0; i--) {
            Rice r0 = _rices[i];
            if (r0.Fed) continue;
            double dx = cx - r0.X;
            double dy = cy - r0.Y;
            if (dx * dx + dy * dy <= r2) return r0;
        }
        return null;
    }

    bool BowlHit(int cx, int cy) { return BowlAt(cx, cy) != null; }

    protected override void WndProc(ref Message m) {
        if (m.Msg == Native.WM_NCHITTEST) {
            int lp = (int)m.LParam;
            int x = (short)(lp & 0xFFFF), y = (short)((lp >> 16) & 0xFFFF);
            Point cp = PointToClient(new Point(x, y));
            // The bowl has to answer here as well: returning HTTRANSPARENT means the
            // mouse message never reaches this window at all, so OnMouseDown can
            // never pick the bowl up (that is exactly why it stopped dragging).
            bool solid = GirlPixelSolid(cp.X, cp.Y) || BowlHit(cp.X, cp.Y);
            m.Result = (IntPtr)(solid ? Native.HTCLIENT : Native.HTTRANSPARENT);
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) {
            // Grabbing a bowl wins over moving the widget, so it can be pulled off
            // the girl even while they overlap. Bowls are in SCREEN pixels, the event
            // is in client pixels, hence the +Left/+Top.
            Rice grabbed = BowlAt(e.X, e.Y);
            if (grabbed != null) {
                double hw = _riceArt.Width / 2.0;
                _riceGrab = grabbed;
                _riceGrab.Dragging = true;
                _riceGrab.Grounded = false;
                _riceGrab.Bounces = 0;              // a fresh throw gets fresh bounces
                _riceGrab.VX = 0; _riceGrab.VY = 0;
                // Client coords == screen coords (window origin is the screen origin),
                // so the grab offset is simply mouse minus bowl centre. Adding _offX/
                // _offY here made _riceGrabY ~1000 too big, and the first mouse move
                // then teleported the bowl to the top of the screen.
                _riceGrabX = e.X - _riceGrab.X;
                _riceGrabY = e.Y - _riceGrab.Y;
                return;
            }
            _drag = true;
            _snapping = false;
            _dragStart = Cursor.Position;
            _offStart = new Point(_offX, _offY);   // the window itself never moves
        } else if (e.Button == MouseButtons.Right) {
            // Menu only on the girl, always. The window is screen-sized while a
            // bowl is out, so an unguarded right-click anywhere over the bowl would
            // pop the menu; the request is explicitly "right-click the girl only".
            if (GirlPixelSolid(e.X, e.Y)) {
                RefreshMenuChecks();
                _menu.Show(Cursor.Position);
            }
        }
        base.OnMouseDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        if (_riceGrab != null && _riceGrab.Dragging && !_riceGrab.Fed) {
            Point sp = Cursor.Position;                 // screen pixels
            _riceGrab.X = sp.X - _riceGrabX;
            _riceGrab.Y = sp.Y - _riceGrabY;
            Rectangle vs = SystemInformation.VirtualScreen;
            double rr = _riceGrab.R;
            if (_riceGrab.X < vs.Left + rr * 0.4) _riceGrab.X = vs.Left + rr * 0.4;
            if (_riceGrab.X > vs.Right - rr * 0.4) _riceGrab.X = vs.Right - rr * 0.4;
            if (_riceGrab.Y < vs.Top + rr * 0.4) _riceGrab.Y = vs.Top + rr * 0.4;
            if (_riceGrab.Y > vs.Bottom - rr * 0.4) _riceGrab.Y = vs.Bottom - rr * 0.4;
            // Just mark it dirty and let the 33 ms animation tick paint. A mouse
            // sends 100+ moves per second and a full repaint of this screen-sized
            // layered window costs ~24 ms, so repainting here starved the tick loop
            // and made a falling bowl stutter (measured: 195 ms per tick).
            _dirty = true;
        } else if (_drag) {
            // The window cannot move (it is the whole screen), so dragging the girl
            // moves the widget inside it. Clamped to the virtual screen so she can
            // never be pushed out of view.
            Rectangle vs2 = SystemInformation.VirtualScreen;
            Point p = Cursor.Position;
            _offX = _offStart.X + (p.X - _dragStart.X);
            _offY = _offStart.Y + (p.Y - _dragStart.Y);
            if (_offX < 0) _offX = 0;
            if (_offX > vs2.Width - _w) _offX = vs2.Width - _w;
            if (_offY < 0) _offY = 0;
            if (_offY > vs2.Height - _h) _offY = vs2.Height - _h;
            _dirty = true;              // painted by the next animation tick, not here
        }
        base.OnMouseMove(e);
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        if (_riceGrab != null && _riceGrab.Dragging) {
            Rice bowl = _riceGrab;
            bowl.Dragging = false;
            _riceGrab = null;
            // Released at height -> a real fall. The allowance is set from the DROP
            // HEIGHT here, so letting go just above the floor gives no rattle while a
            // drop from up high bounces the full three times.
            double floorY = SystemInformation.VirtualScreen.Bottom - bowl.R;
            bowl.MaxBounces = BouncesForDrop(Math.Max(0, floorY - bowl.Y));
            bowl.Bounces = 0;
            if (!bowl.Fed && RiceOnGirl(bowl)) OnRiceFed(bowl);
            _dirty = true;
        } else if (_drag) {
            _drag = false;
            SnapToCorner(false);        // release -> fly back to the bottom-left
        }
        base.OnMouseUp(e);
    }

    void Quit() {
        try { _timer.Stop(); _poll.Stop(); } catch { }
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        if (_sound != null) { try { _sound.Dispose(); } catch { } }
        SaveState();
        Application.Exit();
    }

    // -------------------------------------------------------------- render ---

    public void RenderToCanvas() {
        if (_canvas == null) return;
        long t0 = _perfPhases ? Stopwatch.GetTimestamp() : 0;

        // Shake offsets first: they decide the widget rect, which is what gets
        // erased and repainted this frame.
        double sx = 0, sy = 0;
        for (int i = 0; i < _hits.Count; i++) {
            Hit h = _hits[i];
            double e = Math.Max(0, 1 - h.T / Hit.Dur);
            // Fixed pixel amplitude instead of one scaled by the sprite: at
            // the old 2cm default the widget was ~113px, so a scale
            // proportional shake rounded away to zero and nothing moved.
            // ~24 rad/s keeps several samples per cycle at 30fps; the old
            // 44 rad/s was undersampled and looked like random jumping.
            sx += Math.Sin(h.T * 24) * 3.2 * e;
            sy += Math.Cos(h.T * 19) * 2.8 * e;
        }
        // hard ceiling: overlapping cues must not fling the sprite off-screen
        double shakeMax = Math.Min(12.0, _w * 0.06);
        if (sx > shakeMax) sx = shakeMax; else if (sx < -shakeMax) sx = -shakeMax;
        if (sy > shakeMax) sy = shakeMax; else if (sy < -shakeMax) sy = -shakeMax;
        int ox = (int)Math.Round(sx), oy = (int)Math.Round(sy);
        _shakeX = ox; _shakeY = oy;      // screen text + floating numbers follow this

        // Everything the widget itself paints fits in this rect: the shake is at
        // most 12 px, hearts rise ~46 px and floaters ~92 px above her head.
        Rectangle widgetRect = new Rectangle(ox + _offX - 16, oy + _offY - 96, _w + 32, _h + 112);
        _dirtyRect = Rectangle.Empty;

        // Does the widget itself have to be repainted? While a bowl falls and nothing
        // else moves it does NOT, and repainting it costs ~7 ms of the 33 ms budget
        // (erase + sprite blit + the tablet text through GDI+). Anything that can
        // change how the widget looks has to be in this test, or the picture freezes.
        //
        // _widgetWasAnimating covers the frame an animation ENDS on: without it the
        // last heart or damage number stays on the canvas, and since nothing repaints
        // that area again it stays on screen for good (--animtail is the regression).
        bool widgetAnimating = _hits.Count > 0 || _floaters.Count > 0 || _hearts.Count > 0 || _snapping;
        bool repaintWidget = widgetAnimating || _widgetWasAnimating
                             || _canvas != _lastCanvas
                             || widgetRect != _lastWidgetRect
                             || PanelKey() != _lastPanelKey;
        // A bowl that overlaps the girl forces a repaint too: erasing the rectangle the
        // bowl used to occupy also erases whatever of HER was underneath it, and if the
        // widget is not repainted afterwards that bite stays missing - the bowl smears
        // her away as it is dragged across her (user-reported). Erasing and then
        // repainting the widget is also what is *correct*: with the bowl gone, the
        // pixels it covered have to show the girl again.
        if (!repaintWidget) {
            for (int i = 0; i < _lastRects.Count; i++) {
                Rectangle r = _lastRects[i];
                if (r == widgetRect) continue;              // the widget itself
                if (!r.IntersectsWith(widgetRect)) continue; // nowhere near her
                repaintWidget = true;
                break;
            }
        }
        _widgetWasAnimating = widgetAnimating;

        // Erase exactly what the PREVIOUS frame painted (a bowl that has moved on, or
        // the widget's old spot). Clearing the whole 2560x1600 canvas every frame
        // cost ~16 MB of writes for 0.8 MB of content. The bookkeeping runs at the
        // END of the frame: swapping the lists here, before this frame's rects are
        // known, left a moved bowl's old position unerased for one frame - and then
        // forgotten, so the ghost stayed on screen for good.
        for (int i = 0; i < _lastRects.Count; i++) {
            Rectangle r = _lastRects[i];
            if (repaintWidget && widgetRect.Contains(r)) continue;   // repainted below
            if (!repaintWidget && r == widgetRect) continue;         // unchanged: keep it
            ClearCanvasRect(r);
            MarkDirty(r);
        }
        _paintRects.Clear();
        _paintRects.Add(widgetRect);       // the canvas holds content here from now on
        _lastWidgetRect = widgetRect;
        _lastCanvas = _canvas;
        _lastPanelKey = PanelKey();

        if (repaintWidget) {
            MarkDirty(widgetRect);
            // The widget's own pixels: one rect-locked buffer, no canvas-wide copy.
            Buf buf = new Buf(_canvas, Rectangle.Intersect(widgetRect, CanvasRect()));
            try {
                Array.Clear(buf.P, 0, buf.P.Length);   // the widget is fully repainted
                BlitLayer(_sprNormal, buf, ox + _offX, oy + _offY, 1.0);
                for (int i = 0; i < _hits.Count; i++) {
                    double pulse = _hits[i].Pulse;
                    if (pulse > 0.01) {
                        // The hurt overlay is toned down as the widget grows: 60% of a
                        // 113px sprite is a readable flash, 60% of a 454px one would
                        // just be a red silhouette.
                        double maxTint = Math.Max(0.30, 0.64 - _scale * 0.75);
                        BlitLayer(_sprRed, buf, ox + _offX, oy + _offY, Math.Min(maxTint, maxTint * pulse));
                    }
                }
                buf.Flush();
            } finally { buf.Dispose(); }
            DrawScreen();                              // transparent screen + text only
            if (!_connected && _lastPollResult.Length > 0) DrawAlert();
        }
        if (_perfPhases) { _phSprite += Ms(t0); t0 = Stopwatch.GetTimestamp(); }

        // Bowl, drawn here (see the note on Rice: a separate window never
        // composited in this environment). Its X/Y are SCREEN pixels, converted to
        // canvas pixels on the way out, which is what lets it fall from the real
        // right edge of the screen even though this window is only widget-sized.
        if (_rices.Count > 0 || _hearts.Count > 0) {
            using (Graphics g = Graphics.FromImage(_canvas)) {
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                DrawRice(g);
            }
        }
        // Bowls are rotated and squashed, so their rect is padded generously: it is
        // only used to erase them next frame.
        for (int i = 0; i < _rices.Count; i++) {
            Rice rc = _rices[i];
            double rad = Math.Max(_riceArt.Width, _riceArt.Height) * 0.95 + 14;
            Rectangle rr = new Rectangle((int)Math.Round(rc.X - rad), (int)Math.Round(rc.Y + rc.R - rad),
                                         (int)Math.Round(rad * 2), (int)Math.Round(rad * 2));
            _paintRects.Add(rr);
            MarkDirty(rr);
        }
        if (_perfPhases) { _phRice += Ms(t0); t0 = Stopwatch.GetTimestamp(); }

        if (_floaters.Count > 0) {
            Rectangle fr = Rectangle.Intersect(
                new Rectangle(_offX - 16, _offY - 200, _w + 32, _h + 220), CanvasRect());
            Buf b2 = new Buf(_canvas, fr);
            try {
                for (int i = 0; i < _floaters.Count; i++) DrawFloater(_floaters[i], b2);
                b2.Flush();
            } finally { b2.Dispose(); }
            MarkDirty(fr);
        }
        if (_perfPhases) { _phFloaters += Ms(t0); t0 = Stopwatch.GetTimestamp(); }

        if (_hearts.Count > 0) {
            using (Graphics g = Graphics.FromImage(_canvas)) {
                g.SmoothingMode = SmoothingMode.None;      // keep the pixels crisp
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                DrawHearts(g);
            }
        }

        BuildHitMap(ox + _offX, oy + _offY);
        if (_perfPhases) { _phHit += Ms(t0); }
        // Hand this frame's boxes to the next frame, which erases them.
        _lastRects.Clear();
        _lastRects.AddRange(_paintRects);
        _dirty = false;
    }

    // Zero one canvas rectangle (a bowl's old position, or the widget's old spot).
    // Rect-locked, so this costs the rect, not the screen.
    void ClearCanvasRect(Rectangle r) {
        if (_canvas == null) return;
        Rectangle c = Rectangle.Intersect(r, CanvasRect());
        if (c.Width <= 0 || c.Height <= 0) return;
        Buf b = new Buf(_canvas, c);
        try { Array.Clear(b.P, 0, b.P.Length); b.Flush(); } finally { b.Dispose(); }
    }

    Rectangle CanvasRect() {
        return new Rectangle(0, 0, _canvas == null ? _w : _canvas.Width,
                                   _canvas == null ? _h : _canvas.Height);
    }

    // Remember a rectangle as changed this frame: it is both the area the system
    // must recomposite and the area erased before the next frame draws. Clipped to
    // the canvas here: during startup the widget rect can sit at a negative y
    // (the corner is not known yet) and LockBits rejects an out-of-range rect.
    void MarkDirty(Rectangle r) {
        Rectangle c = Rectangle.Intersect(r, CanvasRect());
        if (c.Width <= 0 || c.Height <= 0) return;
        _dirtyRect = _dirtyRect.IsEmpty ? c : Rectangle.Union(_dirtyRect, c);
    }

    // Phase timing for --perf. Costs nothing unless the flag turned it on.
    bool _perfPhases;
    double _phSprite, _phScreen, _phSnap, _phRice, _phFloaters, _phHit;
    static double Ms(long since) {
        return (Stopwatch.GetTimestamp() - since) * 1000.0 / Stopwatch.Frequency;
    }
    void ResetPhases() {
        _phSprite = _phScreen = _phSnap = _phRice = _phFloaters = _phHit = 0;
    }
    string PhaseReport(int n) {
        return "  render phases   : sprite+clear " + (_phSprite / n).ToString("0.00") +
               "  screen " + (_phScreen / n).ToString("0.00") +
               "  snapshot " + (_phSnap / n).ToString("0.00") +
               "  bowl " + (_phRice / n).ToString("0.00") +
               "  floaters " + (_phFloaters / n).ToString("0.00") +
               "  hitmap " + (_phHit / n).ToString("0.00") + " ms";
    }

    // src over dst, clipped to the locked rectangle of dst. ox/oy are CANVAS
    // coordinates of the layer's top-left, and the rect is subtracted on the way in
    // so a rect-locked buffer can be written without touching its neighbours.
    void BlitLayer(Bitmap layer, Buf dst, int ox, int oy, double alpha) {
        if (layer == null) return;
        Buf src = new Buf(layer);
        try {
            byte[] sp = src.P, dp = dst.P;
            int ss = src.Stride, ds = dst.Stride;
            int rx = dst.R.X, ry = dst.R.Y;
            for (int y = 0; y < src.H; y++) {
                int ty = y + oy - ry;
                if (ty < 0 || ty >= dst.H) continue;
                int srow = y * ss, drow = ty * ds;
                for (int x = 0; x < src.W; x++) {
                    int tx = x + ox - rx;
                    if (tx < 0 || tx >= dst.W) continue;
                    int si = srow + x * 4;
                    int sa = sp[si + 3];
                    if (sa == 0) continue;
                    Cs.Blend(dp, drow + tx * 4, sp[si + 2], sp[si + 1], sp[si], sa / 255.0 * alpha);
                }
            }
        } finally { src.Dispose(); }
    }

    // The hit map decides where the window is clickable and where it lets the
    // mouse through (WM_NCHITTEST), and where a bowl counts as delivered.
    //
    // It is the GIRL ALONE, and it comes from the SPRITE's alpha, never from the
    // finished canvas: reading the canvas folded the bowl in, which made the
    // bowl's pixels count as "the girl" - the right-click menu then opened on the
    // bowl and the delivery test matched the bowl against itself.
    //
    // Building it from the cached silhouette instead of the canvas also removed a
    // full canvas lock + 16 MB read-back on every frame, and made the map follow
    // her while she is dragged (the canvas version was only rebuilt on a resize,
    // so it lagged behind wherever she had been moved to).
    void BuildHitMap(int ox, int oy) {
        int cw = _canvas == null ? _w : _canvas.Width;
        int ch = _canvas == null ? _h : _canvas.Height;
        if (_charHitMap == null || _charHitMap.Length != cw * ch) {
            _charHitMap = new byte[cw * ch];
            _girlStampedOn = null;
            _girlStamped = false;
        }
        // One array, two names: keeping a second copy only cost a 4 MB memcpy per
        // frame. Every writer goes through the stamp below.
        _hitMap = _charHitMap; _hitW = cw; _hitH = ch;
        StampGirlAlpha(ox, oy);
    }

    // The panel bitmap carries ONLY the label and the number. The tablet screen
    // is an opaque black surface in the artwork, so the text is drawn light.
    // The panel size comes from the tablet's quad, so it cannot grow: a longer
    // number has to be drawn smaller instead (see FitDigitsSize).
    void PanelSize(out int pw, out int ph) {
        float lw = (float)Math.Sqrt(Math.Pow(_fx[1] - _fx[0], 2) + Math.Pow(_fy[1] - _fy[0], 2));
        float lh = (float)Math.Sqrt(Math.Pow(_fx[3] - _fx[0], 2) + Math.Pow(_fy[3] - _fy[0], 2));
        pw = 520;
        ph = (int)Math.Round(pw * (lh / lw));
        if (ph < 24) { ph = 24; pw = (int)Math.Round(ph * (lw / lh)); }
    }

    // The width the digits may use: the panel minus the currency sign, minus a margin
    // so the number never touches the tablet's frame. 3 % is deliberate: the original
    // layout put "30.00" at 88 % of the panel, so anything up to two integer digits
    // keeps the font size it always had and only longer numbers start shrinking.
    const float PanelMargin = 0.03f;

    string BalanceText() {
        return double.IsNaN(DrawnBalance) ? "--"
             : DrawnBalance.ToString("0.00", CultureInfo.InvariantCulture);
    }

    // The font size the digits get: whatever fits in the room left after the currency
    // sign, never larger than the original size and never smaller than the
    // readability floor. Shared by the renderer and --panelcheck so the two cannot
    // disagree about what "fits" means.
    static float DigitSizeFor(Graphics g, float W, float H, string txt, float signWidth) {
        float size = H * 0.48f;
        float floorSize = H * 0.17f;
        float room = W * (1 - 2 * PanelMargin) - signWidth;
        if (room < 8f) room = 8f;
        SizeF sd;
        using (Font f = new Font("Arial", size, FontStyle.Bold, GraphicsUnit.Pixel))
            sd = g.MeasureString(txt, f);
        for (int i = 0; i < 5 && sd.Width > room && size > floorSize; i++) {
            float next = size * (room / sd.Width);
            if (next < floorSize) next = floorSize;
            if (next >= size) break;
            size = next;
            using (Font f = new Font("Arial", size, FontStyle.Bold, GraphicsUnit.Pixel))
                sd = g.MeasureString(txt, f);
        }
        return size;
    }

    // ------------------------------------------------ panel / number layout ---
    // The tablet screen is a fixed-size surface, so the number shrinks as digits are
    // added instead of running off the panel. This reports every shape of balance and
    // writes a sheet of the real panels, so the fit can be judged by eye too.
    public void PanelCheckReport() { PanelCheckReport(true); }

    public void PanelCheckReport(bool writeSheet) {
        int pw, ph;
        PanelSize(out pw, out ph);
        float avail = pw * (1 - 2 * PanelMargin);
        Console.WriteLine("panel " + pw + "x" + ph + "px  margin " + (PanelMargin * 100).ToString("0") +
                          "%  digits area " + avail.ToString("0") + "px");
        string[] tests = new string[] { "0.00", "9.99", "30.00", "99.99", "100.00",
                                        "999.99", "1000.00", "99999.99", "1234567.89", "--" };
        int over = 0;
        using (Bitmap probe = new Bitmap(8, 8, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(probe))
        using (Font fc = new Font("Microsoft YaHei UI", ph * 0.27f, FontStyle.Bold, GraphicsUnit.Pixel)) {
            SizeF sc = g.MeasureString("\u00A5", fc);
            Console.WriteLine("  currency sign stays at " + (ph * 0.27f).ToString("0") +
                              "px (width " + sc.Width.ToString("0") + "px)");
            for (int i = 0; i < tests.Length; i++) {
                float size = DigitSizeFor(g, pw, ph, tests[i], sc.Width);
                SizeF sd;
                using (Font f = new Font("Arial", size, FontStyle.Bold, GraphicsUnit.Pixel))
                    sd = g.MeasureString(tests[i], f);
                float total = sd.Width + sc.Width;
                bool fits = total <= avail + 0.5f;
                if (!fits) over++;
                Console.WriteLine("  " + tests[i].PadRight(11) +
                                  " font=" + size.ToString("0.0").PadLeft(6) +
                                  "px  digits=" + sd.Width.ToString("0").PadLeft(4) +
                                  "px  number+sign=" + total.ToString("0").PadLeft(4) +
                                  "px  " + (fits ? "fits" : "OVERFLOW"));
            }
        }
        int cols = tests.Length;
        if (writeSheet) {
            // Two rows: the auto-fitting layout, and the old fixed-size one right under
            // it, so the overflow it used to cause is visible at a glance.
            using (Bitmap sheet = new Bitmap(cols * (pw + 12) + 12, ph * 2 + 60, PixelFormat.Format32bppArgb))
            using (Graphics sg = Graphics.FromImage(sheet)) {
                sg.Clear(Color.FromArgb(255, 236, 238, 244));
                using (Font tag = new Font("Arial", 16, FontStyle.Bold, GraphicsUnit.Pixel))
                using (Brush tb = new SolidBrush(Color.FromArgb(255, 70, 70, 80))) {
                    sg.DrawString("AUTO FIT (new): digits shrink as needed", tag, tb, 12, 6);
                    sg.DrawString("FIXED SIZE (old): did not fit the tablet", tag, tb, 12, 24 + ph + 12);
                }
                for (int i = 0; i < cols; i++) {
                    using (Bitmap pn = BuildPanel(pw, ph, tests[i]))
                        sg.DrawImage(pn, 12 + i * (pw + 12), 24, pw, ph);
                    using (Bitmap pn = BuildPanelFixed(pw, ph, tests[i]))
                        sg.DrawImage(pn, 12 + i * (pw + 12), 24 + ph + 18, pw, ph);
                }
                sheet.Save(Path.Combine(_baseDir, "_panel_sheet.png"), ImageFormat.Png);
            }
            Console.WriteLine("  panel sheet -> _panel_sheet.png (auto-fit on top, old fixed size below)");
        }
        Console.WriteLine("  verdict: " + (over == 0
            ? "OK - every number fits inside the tablet screen"
            : "FAIL - " + over + " numbers overflow the panel"));
    }

    Bitmap BuildPanel(int pw, int ph) { return BuildPanel(pw, ph, BalanceText()); }

    // The old behaviour: the digits were always drawn at H*0.48 with no width check,
    // which is what let "100.00" run off the tablet. Kept only so --panelcheck can
    // show the difference side by side.
    Bitmap BuildPanelFixed(int pw, int ph, string txt) {
        Bitmap panel = new Bitmap(pw, ph, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(panel)) {
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            float W = pw, H = ph;
            using (Font fb = new Font("Arial", H * 0.48f, FontStyle.Bold, GraphicsUnit.Pixel))
            using (Brush bb = new SolidBrush(Color.FromArgb(255, 240, 246, 255))) {
                SizeF sb = g.MeasureString(txt, fb);
                g.DrawString(txt, fb, bb, (W - sb.Width) / 2f, H * 0.44f);
            }
        }
        return panel;
    }

    Bitmap BuildPanel(int pw, int ph, string txt) {
        Bitmap panel = new Bitmap(pw, ph, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(panel)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;

            float W = pw, H = ph;
            using (StringFormat sf = new StringFormat()) {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;

                float fLabel = H * 0.21f;
                using (Font f = new Font("Microsoft YaHei UI", fLabel, FontStyle.Bold, GraphicsUnit.Pixel))
                using (Brush shadow = new SolidBrush(Color.FromArgb(150, 0, 0, 0)))
                using (Brush b = new SolidBrush(Color.FromArgb(235, 158, 182, 224))) {
                    RectangleF lr = new RectangleF(0, H * 0.04f, W, fLabel * 1.5f);
                    g.DrawString(S_LABEL, f, shadow, new RectangleF(lr.X + 1.5f, lr.Y + 1.5f, lr.Width, lr.Height), sf);
                    g.DrawString(S_LABEL, f, b, lr, sf);
                }

                float fCur = H * 0.27f;
                using (Font fc = new Font("Microsoft YaHei UI", fCur, FontStyle.Bold, GraphicsUnit.Pixel))
                using (Brush sh = new SolidBrush(Color.FromArgb(160, 0, 0, 0)))
                using (Brush bb = new SolidBrush(Color.FromArgb(255, 240, 246, 255)))
                using (Brush bc = new SolidBrush(Color.FromArgb(235, 158, 184, 230))) {
                    SizeF sc = g.MeasureString("\u00A5", fc);

                    // The digits get whatever width is left after the sign and the
                    // margins. The panel itself cannot grow (its size is the tablet's
                    // screen), so a longer number is drawn SMALLER instead of running
                    // off the tablet - "100.00" used to spill over the frame. The sign
                    // and the label keep their size, as asked.
                    float fBal = DigitSizeFor(g, W, H, txt, sc.Width);
                    SizeF sb, sbFull;
                    using (Font f0 = new Font("Arial", H * 0.48f, FontStyle.Bold, GraphicsUnit.Pixel))
                        sbFull = g.MeasureString(txt, f0);

                    using (Font fb = new Font("Arial", fBal, FontStyle.Bold, GraphicsUnit.Pixel)) {
                        sb = g.MeasureString(txt, fb);
                        float total = sb.Width + sc.Width;
                        float left = (W - total) / 2f;
                        // Keep the block's vertical CENTRE where it was: a smaller
                        // number would otherwise sit lower than the old one.
                        float top = H * 0.44f + (sbFull.Height - sb.Height) * 0.5f;
                        g.DrawString("\u00A5", fc, sh, left + 1.5f, top + sb.Height * 0.24f + 1.5f);
                        g.DrawString(txt, fb, sh, left + sc.Width + 1.5f, top + 1.5f);
                        g.DrawString("\u00A5", fc, bc, left, top + sb.Height * 0.24f);
                        g.DrawString(txt, fb, bb, left + sc.Width, top);
                    }
                }
            }
        }
        return panel;
    }

    void DrawScreen() {
        int pw, ph;
        PanelSize(out pw, out ph);
        if (pw < 8 || ph < 8) return;

        Bitmap panel = BuildPanel(pw, ph);
        try {
            using (Graphics g = Graphics.FromImage(_canvas)) {
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                PointF[] dest = new PointF[3];
                float bx = (float)(_offX + _shakeX), by = (float)(_offY + _shakeY);
                dest[0] = new PointF((float)_fx[0] + bx, (float)_fy[0] + by);
                dest[1] = new PointF((float)_fx[1] + bx, (float)_fy[1] + by);
                dest[2] = new PointF((float)_fx[3] + bx, (float)_fy[3] + by);
                g.DrawImage(panel, dest);
            }
        } finally { panel.Dispose(); }
    }

    // offline indicator: a small dot, so the screen keeps showing only the
    // label and the number
    void DrawAlert() {
        using (Graphics g = Graphics.FromImage(_canvas)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float r = Math.Max(2.5f, (float)(_h * 0.032));
            float cx = (float)(_fx[1] + _fx[2]) / 2f + (float)_shakeX + _offX;
            float cy = (float)(_fy[1] + _fy[2]) / 2f + (float)(_h * 0.05) + (float)_shakeY + _offY;
            using (Brush b = new SolidBrush(Color.FromArgb(235, 228, 62, 52)))
                g.FillEllipse(b, cx - r, cy - r, r * 2, r * 2);
            using (Pen p = new Pen(Color.FromArgb(210, 255, 255, 255), Math.Max(1f, r * 0.3f)))
                g.DrawEllipse(p, cx - r, cy - r, r * 2, r * 2);
        }
    }

    void DrawFloater(Floater fl, Buf dst) {
        double t = fl.T / fl.Dur;
        float em = (float)Math.Max(13.0, 34.0 * _scale);
        float pop = t < 0.18 ? (float)(0.62 + 0.38 * (t / 0.18)) : 1f;
        double alpha = t < 0.55 ? 1.0 : (1 - (t - 0.55) / 0.45);
        if (alpha <= 0) return;

        Bitmap bmp = MakeFloaterBitmap(fl.Text, em);
        try {
            Buf src = new Buf(bmp);
            try {
                byte[] p = dst.P, sp = src.P;
                int ds = dst.Stride, ss = src.Stride;
                int w = (int)(src.W * pop), h = (int)(src.H * pop);
                // the shake offset is applied here so the number shakes together
                // with the character instead of hanging in place
                int x0 = fl.X + (int)Math.Round(fl.Jitter * Math.Sin(t * 9)) + (int)Math.Round(_shakeX) + _offX;
                int y0 = fl.Y - (int)Math.Round(t * em * 2.7) + (int)Math.Round(_shakeY) + _offY;
                // Clip against the LOCKED RECT (canvas coordinates), not the widget:
                // x0/y0 already include _offX/_offY, so testing them against _w/_h
                // (~454) threw every floater away and the damage numbers vanished.
                int rx = dst.R.X, ry = dst.R.Y;
                for (int yy = 0; yy < h; yy++) {
                    int syy = (int)(yy / pop); if (syy >= src.H) break;
                    int ty = y0 + yy - ry; if (ty < 0 || ty >= dst.H) continue;
                    for (int xx = 0; xx < w; xx++) {
                        int sxx = (int)(xx / pop); if (sxx >= src.W) break;
                        int tx = x0 + xx - rx; if (tx < 0 || tx >= dst.W) continue;
                        int si = syy * ss + sxx * 4;
                        int sa = sp[si + 3]; if (sa == 0) continue;
                        Cs.Blend(p, ty * ds + tx * 4, sp[si + 2], sp[si + 1], sp[si], sa / 255.0 * alpha);
                    }
                }
            } finally { src.Dispose(); }
        } finally { bmp.Dispose(); }
    }

    Bitmap MakeFloaterBitmap(string text, float em) {
        // "+x.xx" is money coming back, so it reads green; everything else is a
        // charge and stays red. Decided from the text so every caller gets it.
        bool gain = text.Length > 0 && text[0] == '+';
        Color fillCol = gain ? Color.FromArgb(255, 58, 220, 90) : Color.FromArgb(255, 255, 72, 60);
        Color edgeCol = gain ? Color.FromArgb(255, 8, 85, 28) : Color.FromArgb(255, 92, 8, 8);
        using (Font f = new Font("Arial", em, FontStyle.Bold, GraphicsUnit.Pixel)) {
            Size sz = TextRenderer.MeasureText(text, f, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding);
            int pad = (int)(em * 0.45f);
            Bitmap bmp = new Bitmap(Math.Max(4, sz.Width + pad * 2), Math.Max(4, sz.Height + pad * 2),
                                    PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                using (GraphicsPath path = new GraphicsPath()) {
                    path.AddString(text, f.FontFamily, (int)FontStyle.Bold, em, new PointF(pad, pad),
                                   StringFormat.GenericTypographic);
                    using (Pen outline = new Pen(edgeCol, em * 0.16f)) {
                        outline.LineJoin = LineJoin.Round;
                        g.DrawPath(outline, path);
                    }
                    using (Brush fill = new SolidBrush(fillCol))
                        g.FillPath(fill, path);
                }
            }
            return bmp;
        }
    }

    // ---------------------------------------------------------------- tick ---

    void OnTick() {
        try {
            if (_pollWant != 0) { int want = _pollWant; _pollWant = 0; PollNow(want == 2); }

            double dt = _timer.Interval / 1000.0;
            bool anim = false;

            if (_snapping) {
                _snapT += dt / 0.16;
                if (_snapT >= 1) { _offX = _snapTo.X; _offY = _snapTo.Y; _snapping = false; }
                else {
                    double e = 1 - Math.Pow(1 - _snapT, 3);
                    _offX = (int)Math.Round(_snapFrom.X + (_snapTo.X - _snapFrom.X) * e);
                    _offY = (int)Math.Round(_snapFrom.Y + (_snapTo.Y - _snapFrom.Y) * e);
                }
                RenderToCanvas();
                PushLayer();
            }

            _lastCueAmount = 0;              // diagnostics: what fired this frame
            DrainBankedBalance();            // apply any reading that arrived

            if (_dueGap > 0) _dueGap -= dt;

            // A freshly fed bowl buys a short pause before any spending animation.
            // A rehearsal credits money that the cloud never had, so the very next
            // poll books it straight back as debt and the girl starts losing health
            // the instant the hearts appear. The delay is purely for demonstration:
            // the debt still accumulates, it just waits.
            if (_cueGrace > 0) _cueGrace -= dt;
            else _cueGrace = 0;

            // The ONLY place the printed number moves: one cent per cue, never
            // more, and never without a cue. The debt is re-derived every time a
            // reading lands, so a reading arriving mid-cue can never strand it.
            double take = 0;
            if (_dueGap <= 0 && _pendingStep <= 0 && _cueGrace <= 0) {
                if (_pending >= StepYuan - 1e-9) take = StepYuan;
                else if (_pending > 1e-9) take = Math.Round(_pending, 2);   // sub-cent sliver
            }
            if (take > 0) {
                _pending = Math.Round(_pending - take, 4);
                if (_pending < 1e-9) _pending = 0;
                _bookedAt = Math.Round(_bookedAt - take, 4);
                _bookedBal = Math.Round(_bookedBal - take, 4);
                _pendingStep = take;
                _dueGap = CueGapSec;
            }

            // The cue itself fires once the previous floater has finished rising:
            // The cue fires as soon as its slot is due. It deliberately does NOT
            // wait for the previous number to finish flying: with a 0.2s rhythm
            // that wait would stretch every cue to over a second. The numbers
            // stack upwards instead, comet-style, so a run of cues still reads
            // clearly.
            if (_pendingStep > 0) {
                _lastCueAmount = _pendingStep;
                MakeTick(_pendingStep, false);
                _pendingStep = 0;
                anim = true;
            }

            // Rehearsal run: same rhythm as real charges, so a custom amount shows
            // exactly what a burst of real spending looks like. The printed number
            // walks down; the books stay untouched.
            if (_demoLeft > 0 && _pendingStep <= 0 && _dueGap <= 0) {
                _lastCueAmount = _demoAmount;
                MakeTick(_demoAmount, true);
                _demoLeft--;
                _dueGap = CueGapSec;
                anim = true;
            }
            for (int i = _hits.Count - 1; i >= 0; i--) {
                _hits[i].T += dt; anim = true;
                if (_hits[i].Done) _hits.RemoveAt(i);
            }
            for (int i = _floaters.Count - 1; i >= 0; i--) {
                _floaters[i].T += dt; anim = true;
                if (_floaters[i].Done) _floaters.RemoveAt(i);
            }

            // Top-up bowl, its hearts and the linear recovery of the readout.
            UpdateRice(dt);
            if (_rices.Count > 0 || _hearts.Count > 0) anim = true;

            if (anim || _dirty) { RenderToCanvas(); PushLayer(); }
        } catch (Exception ex) { Log("tick: " + ex); }
    }

    // fromTest: the menu / tray "test one charge" cue only pretends to spend.
    // It plays the animation and drops the printed number through _testOffset
    // while leaving _realBal and the step yardstick alone, so a later balance
    // refresh neither corrects the number back up nor mistakes the rehearsal for
    // money actually spent. There is deliberately no cap on the offset: capping
    // it used to freeze the number after ten cues. The printed value clamps at
    // zero instead, and any real spending clears the offset.
    void MakeTick(double amount, bool fromTest) {
        // Cap the simultaneous hurt overlays. Real charges are already capped by
        // the tick loop, but repeatedly clicking "test one charge" used to stack
        // an unbounded number of them and each one added its own shake, which
        // added up to a sprite flying across the screen.
        if (_hits.Count < 3) _hits.Add(new Hit());
        if (fromTest) {
            _testOffset = Math.Round(_testOffset + amount, 4);
        } else {
            _testOffset = 0;                         // real movement clears rehearsals
        }
        Floater fl = new Floater();
        fl.Text = "-" + amount.ToString("0.####", CultureInfo.InvariantCulture);
        fl.X = _headX - (int)(_w * 0.06);
        // Cascade: each number that is still in the air pushes the next one up, so
        // a fast run reads as a comet trail instead of a stack printed in place.
        // Counted over a short window, otherwise a long flight would fling a later
        // cue far above the head.
        int trail = 0;
        for (int i = 0; i < _floaters.Count; i++) if (_floaters[i].T < 0.5) trail++;
        if (trail > 3) trail = 3;
        fl.Y = _headY - (int)Math.Round(trail * _floaterStep);
        fl.Jitter = 7 * _scale;
        _floaters.Add(fl);
        if (_floaters.Count > 20) _floaters.RemoveAt(0);
        PlayHitSound();          // every pop plays, even on top of the last one
        _dirty = true;
    }

    void MakeTick(double amount) { MakeTick(amount, false); }

    // Every damage number plays the cue on its own MCI alias, so a new hit never
    // cuts off the previous one.
    void PlayHitSound() {
        if (_sound == null || !_soundEnabled) return;
        int slot = _sound.Play();
        if (slot < 0) {
            Log("sound: nothing played (failed=" + _sound.Failed + " err=" + _sound.Error + ")");
            _soundEnabled = false;                       // do not spam the log
        }
    }

    // ------------------------------------------------------------- polling ---
    //
    // Two transports: .NET HttpClient first, then the local Node runtime. Some
    // locked-down Windows setups make schannel refuse to acquire TLS credentials
    // for .NET while Node ships its own OpenSSL stack and still works.

    static readonly HttpClient Http = CreateClient();
    static HttpClient CreateClient() {
        try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
        HttpClient c = new HttpClient();
        c.Timeout = TimeSpan.FromSeconds(15);
        return c;
    }

    static string _nodePath;
    static bool _nodeSearched;
    static string FindNode() {
        if (_nodeSearched) return _nodePath;
        _nodeSearched = true;

        string explicitPath = Environment.GetEnvironmentVariable("DSHPET_NODE");
        if (!string.IsNullOrEmpty(explicitPath) && File.Exists(explicitPath)) { _nodePath = explicitPath; return _nodePath; }

        string fromPath = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrEmpty(fromPath)) {
            foreach (string dir in fromPath.Split(';')) {
                if (dir.Trim().Length == 0) continue;
                try {
                    string cand = Path.Combine(dir.Trim(), "node.exe");
                    if (File.Exists(cand)) { _nodePath = cand; return _nodePath; }
                } catch { }
            }
        }
        string[] roots = new string[] {
            Environment.GetEnvironmentVariable("ProgramFiles"),
            Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
            Environment.GetEnvironmentVariable("ProgramW6432"),
            Environment.GetEnvironmentVariable("LOCALAPPDATA"),
            Environment.GetEnvironmentVariable("APPDATA")
        };
        foreach (string r in roots) {
            if (string.IsNullOrEmpty(r)) continue;
            try {
                foreach (string sub in new string[] { "nodejs\\node.exe", "Programs\\nodejs\\node.exe",
                                                      "nvm\\current\\node.exe" }) {
                    string cand = Path.Combine(r, sub);
                    if (File.Exists(cand)) { _nodePath = cand; return _nodePath; }
                }
                if (Directory.Exists(r)) {
                    foreach (string d in Directory.GetDirectories(r, "node-v*")) {
                        string cand = Path.Combine(d, "node.exe");
                        if (File.Exists(cand)) { _nodePath = cand; return _nodePath; }
                    }
                }
            } catch { }
        }
        return _nodePath;
    }

    string FetchBalance() {
        try {
            return FetchWithHttp();
        } catch (Exception ex) {
            Log("http transport failed (" + ex.GetType().Name + ": " + ex.Message + "), trying node");
        }
        return FetchWithNode();
    }

    string FetchWithHttp() {
        HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Get, _apiUrl);
        if (_isAccount) req.Headers.TryAddWithoutValidation("x-dsh-auth-token", Secret);
        else req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + Secret);
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        HttpResponseMessage resp = Http.SendAsync(req).GetAwaiter().GetResult();
        string body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        if (!resp.IsSuccessStatusCode) throw new Exception("HTTP " + (int)resp.StatusCode);
        return body;
    }

    string FetchWithNode() {
        string node = FindNode();
        if (node == null) throw new Exception("node not found");
        // The header name and value ride in on the environment so both credential
        // shapes work over the Node transport too.
        string script =
            "const h=require('https');const u=process.env.DSHPET_URL;" +
            "const hn=process.env.DSHPET_HEADER||'Authorization';" +
            "const hv=process.env.DSHPET_HEADERVAL||('Bearer '+process.env.DSHPET_KEY);" +
            "const o={headers:{Accept:'application/json'}};o.headers[hn]=hv;" +
            "const r=h.get(u,o," +
            "s=>{let b='';s.on('data',c=>b+=c);s.on('end',()=>{process.stdout.write(b)})});" +
            "r.on('error',e=>{console.error(String(e.message||e));process.exit(2)});" +
            "r.setTimeout(15000,()=>{console.error('timeout');process.exit(3)});";

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = node;
        psi.Arguments = "-e \"" + script.Replace("\"", "\\\"") + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.EnvironmentVariables["DSHPET_URL"] = _apiUrl;
        psi.EnvironmentVariables["DSHPET_KEY"] = _apiKey;
        psi.EnvironmentVariables["DSHPET_HEADER"] = _isAccount ? "x-dsh-auth-token" : "Authorization";
        psi.EnvironmentVariables["DSHPET_HEADERVAL"] = _isAccount ? Secret : ("Bearer " + Secret);
        using (Process p = Process.Start(psi)) {
            string outp = p.StandardOutput.ReadToEnd();
            string errp = p.StandardError.ReadToEnd();
            if (!p.WaitForExit(20000)) { try { p.Kill(); } catch { } throw new Exception("node timeout"); }
            if (p.ExitCode != 0 || outp.Trim().Length == 0)
                throw new Exception("node exit " + p.ExitCode + " " + Trunc(errp));
            if (!LooksLikeBalance(outp)) throw new Exception("node: " + Trunc(outp));
            return outp;
        }
    }

    // A 200 with an error envelope must not be mistaken for a reading, and the
    // two credential shapes answer with different envelopes.
    bool LooksLikeBalance(string body) {
        if (_isAccount) return body.IndexOf("\"normal_wallets\"") >= 0 || body.IndexOf("\"bonus_wallets\"") >= 0;
        return body.IndexOf("is_available") >= 0;
    }

    static string Trunc(string s) {
        if (s == null) return "";
        s = s.Replace("\r", " ").Replace("\n", " ");
        return s.Length > 200 ? s.Substring(0, 200) : s;
    }

    // snap = the user asked for it (the menu's "refresh now", or --shot): the
    // tablet jumps straight to the value just read. snap = false is the
    // background poll, which keeps walking down in whole steps so every step
    // still gets its hurt animation. Synchronous either way, so a menu click is
    // answered on the spot and always logged.
    // The fetch runs on a worker thread and the result is banked for the next
    // frame: with the poll now every couple of seconds, doing the HTTP call on
    // the UI thread would visibly freeze the widget. The banked reading is
    // applied by OnTick, so the tablet still reacts within one frame of it
    // arriving. Only one request is ever in flight.
    void PollNow(bool snap) {
        if (!HasSecret) {
            _connected = false;
            _status = S_NOKEY;
            _lastPollResult = "no credentials";
            _dirty = true;
            Log("poll skipped: no credentials (menu: " + S_SETKEY + ")");
            return;
        }
        if (Interlocked.CompareExchange(ref _pollInFlight, 1, 0) != 0) return;
        bool wantSnap = snap;
        ThreadPool.QueueUserWorkItem(delegate {
            try {
                string body = FetchBalance();
                double bal = ParseAnyCny(body);
                if (double.IsNaN(bal)) { Fail("cannot parse response: " + Trunc(body)); return; }
                lock (_hits) { _bankedBal = bal; _bankedSnap = wantSnap; _bankedValid = true; }
            } catch (Exception ex) {
                Fail(ex.Message);
            } finally {
                Interlocked.Exchange(ref _pollInFlight, 0);
            }
        });
    }

    // applies a banked reading; called from the render tick
    void DrainBankedBalance() {
        // Offline self-tests must ignore even a reading that was already
        // fetched: a request issued during start-up can land in the middle of a
        // simulated sequence and wipe the pending amount, which made the test
        // (and this bug hunt) lie.
        if (_noNetwork) { lock (_hits) { _bankedValid = false; } return; }
        double bal; bool snap;
        lock (_hits) {
            if (!_bankedValid) return;
            bal = _bankedBal; snap = _bankedSnap; _bankedValid = false;
        }
        ApplyBalance(bal, snap);
        Log("poll ok" + (snap ? " (snap)" : "") +
            ": balance=" + bal.ToString("0.00", CultureInfo.InvariantCulture) +
            " printed=" + DrawnText +
            " bookedAt=" + (double.IsNaN(_bookedAt) ? -1 : _bookedAt) +
            " pending=" + _pending.ToString("0.####", CultureInfo.InvariantCulture));
    }

    // blocking variant, used by the offline self-tests only
    void PollNowSync(bool snap) {
        try {
            string body = FetchBalance();
            double bal = ParseAnyCny(body);
            if (double.IsNaN(bal)) { Fail("cannot parse response: " + Trunc(body)); return; }
            ApplyBalance(bal, snap);
        } catch (Exception ex) { Fail(ex.Message); }
    }

    // The whole balance bookkeeping lives here. Nothing else may move the printed
    // number: the total still owed is always re-derived from
    // (_bookedAt - bal), so a reading that arrives at any moment can never make
    // the display drift on its own.
    void ApplyBalance(double bal, bool snap) {
        lock (_hits) {
            _connected = true;
            _lastPollResult = "";
            bool firstReading = double.IsNaN(_realBal);
            double prevReal = _realBal;
            _realBal = bal;
            bool topUp = false;
            if (firstReading) {
                _bookedAt = bal;
                _bookedBal = bal;
                _pending = 0;
            } else if (snap) {
                // "refresh now" is an explicit resync: believe the server exactly,
                // drop rehearsals, queued debt AND any uncollected top-up. It must
                // not go through the top-up path - a scenario that re-reads the
                // same balance would otherwise book a phantom cent every time.
                _bookedAt = bal;
                _bookedBal = bal;
                _creditPending = 0;
                _testOffset = 0;
                _pending = 0;
                _pendingStep = 0;
                _dueGap = 0;
            } else if (bal > prevReal + 1e-6) {
                // ------------------------------------------------------ top-up --
                // The server balance went UP. This is money being added, not a
                // correction, so the readout must NOT follow it: the difference
                // goes into _creditPending and is only collected when the player
                // drags the bowl of rice onto the girl. Until then the printed
                // number stays exactly where it was.
                _bookedBal = double.IsNaN(_bookedBal) ? bal : _bookedBal;   // freeze
                StartCredit(Math.Round(bal - prevReal, 4));
                topUp = true;
            } else if (bal < prevReal - 1e-6 && _creditPending > StepYuan * 0.5) {
                // The server figure moved DOWN while a top-up is uncollected.
                //
                // Whether that means spending depends on where the NEW figure sits
                // relative to the readout:
                //   new >= printed : the money is still on the server (a rehearsal
                //                    whose local bump was undone by a real poll, or a
                //                    partial spend). Keep/re-derive what is owed.
                //   new <  printed : the money was really spent, so shrink the debt.
                // Comparing the readout against the new figure instead - what this
                // used to do - booked the rehearsal rollback as spending and emptied
                // the bowl, so a delivered bowl credited nothing.
                if (bal >= _bookedBal - 1e-6) {
                    // The new figure is still at or above the readout, so the money is
                    // still on the server: the top-up stands and what is owed is
                    // unchanged. Do NOT re-derive it from (bal - _bookedBal) - that is
                    // 0 here, and overwriting with 0 is exactly what emptied the bowl
                    // (the rehearsal's local bump being undone by a real poll).
                } else {
                    double drop = Math.Round(_bookedBal - bal, 4);
                    _creditPending = Math.Round(_creditPending - drop, 4);
                    if (_creditPending < 0) _creditPending = 0;
                    Log("spend while top-up pending: -" +
                        drop.ToString("0.00", CultureInfo.InvariantCulture) +
                        " left=" + _creditPending.ToString("0.00", CultureInfo.InvariantCulture));
                }
                topUp = true;                 // do not treat this as a fresh debt
            }
            if (DiagBalance) {
                Log("BALDIAG prevReal=" + prevReal.ToString("0.0000") +
                    " bal=" + bal.ToString("0.0000") +
                    " bookedBal=" + _bookedBal.ToString("0.0000") +
                    " pending=" + _creditPending.ToString("0.0000") +
                    " topUp=" + topUp + " snap=" + snap + " first=" + firstReading);
            }
            // A top-up must skip the debt block entirely: it would compute a
            // NEGATIVE owed (-5.00), and the "correction" branch below would then
            // re-anchor the readout straight onto the new balance, defeating the
            // whole point of the bowl.
            if (!firstReading && !snap && !topUp) {
                // The whole difference becomes the debt. A cue already committed
                // but not yet charged counts as part of it, so it is subtracted
                // rather than overwritten - overwriting it is what used to make
                // the number move by less than one animation.
                //
                // _creditPending is ADDED BACK: that money is already inside `bal`
                // (it was a real recharge to the server), it has simply not been
                // collected yet, so it is not a debt. Leaving it out made the debt
                // negative on the poll AFTER a recharge - the balance stops moving
                // once the money lands, so that poll is an ordinary one and took this
                // branch - and the "correction" below then re-anchored the readout
                // onto the live balance. The number climbed on its own a few seconds
                // after a recharge, and delivering the bowl pushed it ABOVE the real
                // balance (user-reported after a real 20 yuan recharge).
                double owed = Math.Round(_bookedAt - bal + _creditPending, 4);
                if (owed < -1e-9) {
                    // the server really is above (booked + uncollected): a recharge that
                    // was never noticed, or a correction. Re-anchor so the debt is only
                    // what is uncharged, and drop the uncollected top-up with it - the
                    // readout now contains that money, so paying the bowl out on top of
                    // it would overshoot.
                    owed = _pending;
                    _bookedAt = Math.Round(bal + owed, 4);
                    _bookedBal = Math.Round(bal + owed, 4);
                    _creditPending = 0;
                }
                if (owed >= _pendingStep - 1e-9) owed = Math.Round(owed - _pendingStep, 4);
                else owed = 0;                    // the cue in flight already covers it
                // one cue is one cent, so cap the queue to keep a huge jump from
                // turning into minutes of animation
                double cap = StepYuan * MaxCuesPerPoll;
                if (owed > cap) owed = cap;
                _pending = owed < 1e-9 ? 0 : owed;
                if (_pending > 1e-9 && _dueGap <= 0) _dueGap = 0;   // first cue now
            }
        }
        _dirty = true;
    }

    void Fail(string why) {
        lock (_hits) { _connected = false; _status = S_LOADING; _lastPollResult = why; }
        Log("poll FAILED: " + why);
        _dirty = true;
    }

    static double ParseCny(string json) {
        int i = json.IndexOf("\"balance_infos\"");
        string scope = i >= 0 ? json.Substring(i) : json;
        int c = scope.IndexOf("\"CNY\"");
        if (c < 0) return double.NaN;
        int j = scope.IndexOf("total_balance", c);
        if (j < 0) return double.NaN;
        int col = scope.IndexOf(':', j);
        if (col < 0) return double.NaN;
        int q1 = scope.IndexOf('"', col + 1);
        if (q1 < 0) return double.NaN;
        int q2 = scope.IndexOf('"', q1 + 1);
        if (q2 < 0) return double.NaN;
        double v;
        if (double.TryParse(scope.Substring(q1 + 1, q2 - q1 - 1), NumberStyles.Float,
                            CultureInfo.InvariantCulture, out v)) return v;
        return double.NaN;
    }

    // Picks the parser that matches the credential in use.
    double ParseAnyCny(string json) {
        return _isAccount ? ParseAccountCny(json) : ParseCny(json);
    }

    // The DSH account endpoint answers with
    //   data.biz_data.{normal_wallets,bonus_wallets}[].{currency,balance}
    // and no total, so the CNY wallets are added up here. "0E-16" is a valid
    // double and parses as zero, which is exactly the empty normal wallet.
    static double ParseAccountCny(string json) {
        double total = 0;
        bool any = false;
        foreach (string array in new string[] { "\"normal_wallets\"", "\"bonus_wallets\"" }) {
            int a = json.IndexOf(array);
            if (a < 0) continue;
            int lb = json.IndexOf('[', a);
            if (lb < 0) continue;
            int rb = json.IndexOf(']', lb);
            if (rb < 0) rb = json.Length;
            string span = json.Substring(lb + 1, rb - lb - 1);
            int cursor = 0;
            while (cursor < span.Length) {
                int ci = span.IndexOf("\"currency\"", cursor);
                if (ci < 0) break;
                int ciColon = span.IndexOf(':', ci);
                string currency = JsonStringAfter(span, ciColon);
                int bi = span.IndexOf("\"balance\"", ci);
                if (bi < 0) break;
                string balance = JsonStringAfter(span, span.IndexOf(':', bi));
                double v;
                if (currency == "CNY" && balance != null && double.TryParse(balance, NumberStyles.Float,
                        CultureInfo.InvariantCulture, out v)) {
                    total += v;
                    any = true;
                }
                cursor = bi + 1;
            }
        }
        return any ? total : double.NaN;
    }

    static string JsonStringAfter(string s, int colon) {
        if (colon < 0) return null;
        int q1 = s.IndexOf('"', colon + 1);
        if (q1 < 0) return null;
        int q2 = s.IndexOf('"', q1 + 1);
        if (q2 < 0) return null;
        return s.Substring(q1 + 1, q2 - q1 - 1);
    }

    void Log(string msg) {
        try {
            File.AppendAllText(Path.Combine(_baseDir, "pet.log"),
                DateTime.Now.ToString("s") + " " + msg + "\r\n");
        } catch { }
    }

    // ---------------------------------------------------------------- entry --

    [STAThread]
    public static void Run(string baseDir, string[] args) {
        // Anything thrown anywhere below is printed with a stack trace before it
        // leaves: the PowerShell host only reports "Exception calling Run", which
        // says nothing about where it came from. error.log gets the full text too.
        try {
            RunInner(baseDir, args);
        } catch (Exception ex) {
            Console.WriteLine("FATAL: " + ex);
            throw;
        }
    }

    [STAThread]
    static void RunInner(string baseDir, string[] args) {
        try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { try { Native.SetProcessDPIAware(); } catch { } }

        bool selftest = Array.IndexOf(args, "--selftest") >= 0;
        bool shot = Array.IndexOf(args, "--shot") >= 0;
        bool menuShot = Array.IndexOf(args, "--menushot") >= 0;
        bool iconShot = Array.IndexOf(args, "--iconshot") >= 0;
        bool topupTest = Array.IndexOf(args, "--topup") >= 0;
        bool simchain = Array.IndexOf(args, "--simchain") >= 0;
        bool perfTest = Array.IndexOf(args, "--perf") >= 0;
        bool ulwTest = Array.IndexOf(args, "--ulwcheck") >= 0;
        bool animTail = Array.IndexOf(args, "--animtail") >= 0;
        bool bowlGirl = Array.IndexOf(args, "--bowlgirl") >= 0;
        bool panelCheck = Array.IndexOf(args, "--panelcheck") >= 0;
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        DshPet pet = new DshPet(baseDir, args);
        if (selftest || shot || menuShot || iconShot || topupTest || simchain || perfTest || ulwTest ||
            animTail || bowlGirl || panelCheck) pet.NoSaveForTest();

        if (shot) {
            System.Windows.Forms.Timer shotTimer = new System.Windows.Forms.Timer();
            shotTimer.Interval = 2500;
            shotTimer.Tick += delegate {
                shotTimer.Stop();
                pet.PollNowSyncPublic(false);
                Console.WriteLine("rest  : " + pet.ShakeReport());

                // menu "refresh now" must print the latest value immediately
                Console.WriteLine("shown after auto poll     = " + pet.DrawnText);
                pet.PollNowSyncPublic(true);
                Console.WriteLine("shown after refresh now   = " + pet.DrawnText +
                                  "   (must equal the live balance)");

                // regression: the number must keep stepping for EVERY rehearsal.
                // It used to freeze after ten because the offset was capped.
                pet.PollNowSyncPublic(true);
                string before = pet.DrawnText;
                for (int i = 1; i <= 15; i++) pet.MakeTick(0.03, true);
                Console.WriteLine("printed before 15 cues    = " + before);
                Console.WriteLine("printed after 15 cues     = " + pet.DrawnText +
                                  "   (must be 0.45 lower, not frozen)");

                // and a rehearsal must not survive a refresh as phantom spend
                for (int i = 1; i <= 3; i++) pet.MakeTick(pet.StepValue, true);
                Console.WriteLine("shown after 3 test cues   = " + pet.DrawnText);
                pet.PollNowSyncPublic(true);
                Console.WriteLine("shown after refresh again = " + pet.DrawnText +
                                  "   <- back to the live balance, no drift");

                // visual check of a fast run: five cues at the real 0.2s rhythm,
                // captured mid-cascade so the trail spacing can be inspected
                pet.ResetDemoForTest();
                pet.PollNowSyncPublic(true);
                pet.DemoCharge(0.05);
                pet.PumpTicks(6);                    // first cue lands
                pet.PumpTicks(6);                    // second, 0.2s later
                pet.PumpTicks(6);                    // third
                pet.SaveCanvas(Path.Combine(baseDir, "_shot_cascade.png"));
                Console.WriteLine("cascade: " + pet.ShakeReport() +
                                  "  floaters=" + pet.FloaterCountPublic +
                                  "  printed=" + pet.DrawnText);
                pet.PumpTicks(360);                  // let the run finish
                Console.WriteLine("cascade settled -> printed " + pet.DrawnText);

                pet.ResetDemoForTest();
                pet.MakeTick(pet.StepValue, true);   // rehearsal for the screenshot
                pet.BurnFrames(2);
                Console.WriteLine("shake1: " + pet.ShakeReport());
                pet.SaveCanvas(Path.Combine(baseDir, "_shot_flash.png"));
                pet.BurnFrames(3);
                Console.WriteLine("shake2: " + pet.ShakeReport());
                pet.BurnFrames(9);
                Console.WriteLine("after : " + pet.ShakeReport());
                pet.SaveCanvas(Path.Combine(baseDir, "shot.png"));
                Console.WriteLine("shot ok: connected=" + pet._connected +
                                  " drawn=" + pet.DrawnText);

                // Top-up visual: drop a bowl without touching the network, let it
                // fall, and capture it so the artwork and its landing can be
                // checked by eye. Also proves the bowl does not disturb the
                // printed number.
                string riceBefore = pet.DrawnText;
                pet.StartCreditPublic(5.00);
                pet.PumpTicks(10);                   // let it start falling
                pet.SaveCanvas(Path.Combine(baseDir, "_shot_rice.png"));
                Console.WriteLine("rice: printed=" + pet.DrawnText +
                                  " (must equal " + riceBefore + ")" +
                                  "  bowl=" + pet.RiceReport());
                // The bowl is its own window now, so SaveCanvas (this window's
                // canvas) cannot show it. Grab the whole desktop instead, which is
                // the only honest way to check WHERE it falls.
                pet.CaptureDesktop(Path.Combine(baseDir, "_shot_desktop.png"));
                Console.WriteLine("geom: " + pet.GeomReport());
                Console.WriteLine("hitmap: " + pet.HitMapReport());
                // Interaction gates: the bowl must be pickable, and the menu must
                // fire on the girl but NOT on the bowl. Both broke silently before.
                {
                    Rice rr = pet.RiceState;
                    if (rr != null) {
                        // Bowl coords are SCREEN and the window origin is the screen
                        // origin, so they are directly comparable to the hit map.
                        int bx = (int)Math.Round(rr.X), by = (int)Math.Round(rr.Y);
                        Console.WriteLine("gates: bowlHitOnBowl=" + pet.BowlHitPublic(bx, by) +
                                          " (want True)  girlSolidOnBowl=" + pet.GirlSolidPublic(bx, by) +
                                          " (want False -> menu must NOT open on the bowl)");
                    }
                    int gx, gy;
                    if (pet.GirlSample(out gx, out gy)) {
                        Console.WriteLine("gates: girlSolidOnGirl=" + pet.GirlSolidPublic(gx, gy) +
                                          " (want True -> menu opens here)  at " + gx + "," + gy +
                                          "  bowlHitOnGirl=" + pet.BowlHitPublic(gx, gy));
                    } else Console.WriteLine("gates: FAIL - no solid girl pixel in the hit map");
                }
                pet.DumpCanvasScaled(Path.Combine(baseDir, "_shot_canvas.png"));
                pet.PumpTicks(60);                   // let it settle
                Console.WriteLine("rice settled: " + pet.RiceReport());
                pet.CaptureDesktop(Path.Combine(baseDir, "_shot_desktop2.png"));
                Console.WriteLine("geom: " + pet.GeomReport());
                Console.WriteLine("rice after settle: " + pet.RiceReport() +
                                  "   bowlBottomOnScreen=" + pet.BowlBottomOnScreen());

                // Deliver it and catch the hearts mid-flight, plus the green "+x.xx"
                // credit number that lands at the same moment.
                pet.FeedRiceForShot();
                pet.PumpTicks(6);
                pet.SaveCanvas(Path.Combine(baseDir, "_shot_hearts.png"));
                Console.WriteLine("hearts: printed=" + pet.DrawnText +
                                  "  bowl=" + pet.RiceReport() +
                                  "  hearts=" + pet.HeartsPublic);
                Application.Exit();
            };
            shotTimer.Start();
            Application.Run(pet);
            return;
        }

        if (Array.IndexOf(args, "--iconshot") >= 0) {
            // Icon sheet: every menu icon at 1x and blown up 8x with no
            // resampling, so the artwork itself can be judged and any shape that
            // runs off its 16x16 cell is obvious.
            int[] kinds = new int[] { IC_REFRESH, IC_BOLT, IC_BOWL, IC_CASCADE, IC_SIZE,
                                      IC_SOUND, IC_KEY, IC_QUIT, IC_MUTE };
            int s = 8, cell = 16, pad = 6;
            int cw = cell * s + pad;
            using (Bitmap sheet = new Bitmap(kinds.Length * cw + pad, cw + cell + pad * 3,
                                             PixelFormat.Format32bppArgb)) {
                using (Graphics g = Graphics.FromImage(sheet)) {
                    g.Clear(Color.White);
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    for (int i = 0; i < kinds.Length; i++) {
                        using (Bitmap ic = MakeIcon(kinds[i])) {
                            int x = pad + i * cw;
                            g.DrawRectangle(Pens.Silver, x, pad, cw - 1, cw - 1);
                            g.DrawImage(ic, new Rectangle(x, pad, cell * s, cell * s));
                            g.DrawImage(ic, new Rectangle(x + (cell * s - cell) / 2, pad + cw + 2, cell, cell));
                        }
                    }
                }
                sheet.Save(Path.Combine(baseDir, "_icon_sheet.png"), ImageFormat.Png);
            }
            Console.WriteLine("icon sheet -> _icon_sheet.png (" + kinds.Length + " icons, 1x and " + s + "x)");
            return;
        }

        // Panel / number layout: how the readout fits the tablet at any digit count.
        if (Array.IndexOf(args, "--panelcheck") >= 0) {
            pet.PanelCheckReport();
            return;
        }

        if (selftest) {
            Console.WriteLine("diag: " + pet.Diag());
            pet.GoOffline();                  // deterministic: no background poll
            pet.RunSelfTest(baseDir);
            Application.Exit();
            return;
        }

        // Frame-budget breakdown (development flag, offline, no window shown but the
        // real handle exists so PushLayer is included).
        if (Array.IndexOf(args, "--perf") >= 0 || Array.IndexOf(args, "--ulwcheck") >= 0 ||
            Array.IndexOf(args, "--animtail") >= 0 || Array.IndexOf(args, "--bowlgirl") >= 0) {
            bool ulw = Array.IndexOf(args, "--ulwcheck") >= 0;
            System.Windows.Forms.Timer pf = new System.Windows.Forms.Timer();
            pf.Interval = 400;
            pf.Tick += delegate {
                pf.Stop();
                try {
                    if (ulw) { Console.WriteLine("layered-window push self-check"); pet.UlwCheckReport(); }
                    else if (Array.IndexOf(args, "--animtail") >= 0) pet.RunAnimationTailTest();
                    else if (Array.IndexOf(args, "--bowlgirl") >= 0) pet.RunBowlOverGirlTest();
                    else pet.PerfReport();
                } catch (Exception ex) { Console.WriteLine("diag FAILED: " + ex); }
                Console.WriteLine("done");
                Application.Exit();
            };
            pf.Start();
            Application.Run(pet);
            return;
        }

        // Menu appearance check. A dropdown is its own popup window, so the only
        // honest way to see the beautified menu is to open it for real and grab
        // that part of the screen. It is never part of a release run: --menushot
        // is a development flag, like --shot.
        if (Array.IndexOf(args, "--menushot") >= 0) {
            pet.GoOffline();                  // no network while the menu is open
            pet.SetVolumeForShot(75);          // so one volume row carries the tick
            int step = 0;
            System.Windows.Forms.Timer mt = new System.Windows.Forms.Timer();
            mt.Interval = 600;
            mt.Tick += delegate {
                Rectangle cap;
                switch (step) {
                case 0:
                    // Show in one tick, capture in the next: the popup needs a pass
                    // through the message loop before it has actually painted.
                    Console.WriteLine("menu: " + pet.MenuReport());
                    pet.OpenRootMenu(pet.MenuOrigin());
                    break;
                case 1:
                    cap = pet.MenuBounds();
                    pet.CaptureRegion(Path.Combine(baseDir, "_menu_1_root.png"), cap, 10);
                    Console.WriteLine("root menu rect: " + cap);
                    pet.OpenSoundMenu();
                    break;
                case 2:
                    cap = pet.MenuBounds();
                    pet.CaptureRegion(Path.Combine(baseDir, "_menu_2_sound.png"), cap, 10);
                    Console.WriteLine("sound menu rect: " + cap);
                    pet.OpenSizeMenu();
                    break;
                case 3:
                    cap = pet.MenuBounds();
                    pet.CaptureRegion(Path.Combine(baseDir, "_menu_3_size.png"), cap, 10);
                    Console.WriteLine("size menu rect: " + cap);
                    Console.WriteLine("metrics: " + pet.MenuMetrics());
                    break;
                default:
                    mt.Stop();
                    pet.CloseMenus();
                    Console.WriteLine("menu shot done");
                    Application.Exit();
                    break;
                }
                step++;
            };
            mt.Start();
            Application.Run(pet);
            return;
        }

        if (Array.IndexOf(args, "--topup") >= 0) {
            pet.RunTopUpTest();
            Console.WriteLine();
            pet.RunTestTopUp();               // the menu entry, same path
            Console.WriteLine();
            pet.RunMultiBowlTest();           // one bowl per top-up
            Console.WriteLine();
            pet.RunResizeWithBowlTest();      // resize with a bowl out
            Console.WriteLine();
            pet.RunSnapBackTest();            // the girl returns to her corner
            Console.WriteLine();
            pet.RunFeedGraceTest();           // the pause before spending resumes
            Console.WriteLine();
            pet.RunSoundTest();               // the sound submenu really applies
            Console.WriteLine();
            pet.RunAnimationTailTest();       // nothing frozen after an animation ends
            Console.WriteLine();
            pet.RunBowlOverGirlTest();        // a bowl must not erase the girl
            Console.WriteLine();
            pet.RunTopUpHoldTest();           // an uncollected top-up stays frozen
            Console.WriteLine();
            pet.PanelCheckReport(false);      // every number shape fits the tablet
            Console.WriteLine();
            return;
        }

        if (Array.IndexOf(args, "--simchain") >= 0) {
            pet.GoOffline();                  // deterministic: no background poll/ticks
            // Feeds a chain of balance readings through the accounting layer and
            // prints what the tablet would show. The number must only fall in
            // whole steps, and a reading that crosses a step must be charged on
            // the spot (not held until the next poll).
            Console.WriteLine("step=" + pet.StepValue.ToString("0.##") +
                              " per cue, " + pet.CueGapText + "s apart" +
                              "   (one cent per animation)");
            // Size presets: prove each cup lands on the intended pixel edge.
            Console.WriteLine("sizes: " + pet.SizePresetReport());
            Console.WriteLine("menu : " + pet.MenuReport());
            // single reading, then watch every tick
            pet.ResetDemoForTest();
            pet.ApplyBalancePublic(30.00, true);
            Console.WriteLine("  reset            : " + pet.StateText);
            pet.ApplyBalancePublic(29.99, false);   // exactly one cent
            Console.WriteLine("  server -> 29.99  : " + pet.StateText);
            for (int i = 1; i <= 6; i++) {
                pet.PumpTicks(1);
                Console.WriteLine("    tick " + i + "         : " + pet.StateText +
                                  "  printed=" + pet.DrawnText);
            }
            Console.WriteLine();

            Console.WriteLine("the reported case: a 0.05 drop becomes FIVE animations");
            pet.ResetDemoForTest();
            pet.ApplyBalancePublic(30.00, true);
            Console.WriteLine("  reset -> printed " + pet.DrawnText + "  (bookedAt " +
                              pet.BookedAtText + ")");
            pet.ApplyBalancePublic(29.95, false);        // 0.05 down
            Console.WriteLine("  server -> 29.95 : owed " +
                              pet.PendingCount.ToString("0.####") +
                              "  -> printed still " + pet.DrawnText);
            for (int i = 1; i <= 8; i++) {
                pet.PumpTicks(9);                        // ~0.3s per sample
                Console.WriteLine("    +0.3s -> printed " + pet.DrawnText +
                                  "  cue " + pet.LastCueText +
                                  "  owed " + pet.PendingCount.ToString("0.####"));
            }
            pet.PumpTicks(120);
            Console.WriteLine("  settled -> printed " + pet.DrawnText +
                              "  (30.00 - 0.05 = 29.95, 5 animations)");
            Console.WriteLine();

            double[] chain = new double[] { 30.00, 29.99, 29.98, 29.97, 29.98, 29.95, 29.90 };
            pet.ResetDemoForTest();
            for (int i = 0; i < chain.Length; i++) {
                pet.ApplyBalancePublic(chain[i], false);
                string line = "  read " + chain[i].ToString("0.00") +
                              " -> printed " + pet.DrawnText;
                pet.PumpTicks(60);                  // let queued cues land
                Console.WriteLine(line + " -> after cues " + pet.DrawnText +
                                  (Math.Abs(pet.PendingCount) > 1e-9
                                     ? "  (still owed " + pet.PendingCount.ToString("0.####") + ")"
                                     : ""));
            }

            Console.WriteLine();
            Console.WriteLine("a big jump is paid off one cent at a time, never merged:");
            pet.ResetDemoForTest();
            pet.ApplyBalancePublic(30.00, true);
            Console.WriteLine("  reset -> printed " + pet.DrawnText);
            pet.ApplyBalancePublic(29.75, false);   // 0.25 down = 25 animations
            for (int i = 1; i <= 6; i++) {
                pet.PumpTicks(24);                  // ~0.8s per sample
                Console.WriteLine("    +0.8s -> printed " + pet.DrawnText +
                                  "  cue " + pet.LastCueText +
                                  "  owed " + pet.PendingCount.ToString("0.####"));
            }
            pet.PumpTicks(900);                     // let the whole run finish
            Console.WriteLine("  settled -> printed " + pet.DrawnText +
                              "  (30.00 - 0.25 = 29.75)");

            Console.WriteLine();
            Console.WriteLine("demo cues only offset what is printed:");
            pet.ResetDemoForTest();
            pet.ApplyBalancePublic(30.00, true);
            Console.WriteLine("  reset -> printed " + pet.DrawnText);
            pet.DemoCharge(0.05);                   // same rhythm as a real burst
            for (int i = 1; i <= 5; i++) {
                pet.PumpTicks(16);
                Console.WriteLine("    +0.53s -> printed " + pet.DrawnText +
                                  "  cuesLeft " + pet.DemoLeftText);
            }
            pet.PumpTicks(200);
            Console.WriteLine("  all demo cues done -> printed " + pet.DrawnText +
                              "  cuesLeft " + pet.DemoLeftText);
            pet.ApplyBalancePublic(29.70, false);   // 0.25 of real spending = 25 cues
            pet.PumpTicks(900);
            Console.WriteLine("  real spend to 29.70 -> printed " + pet.DrawnText +
                              "  (demo offset cleared, real cues paid off)");
            Application.Exit();
            return;
        }

        Application.Run(pet);
    }

    public string Diag() {
        return "cm=" + _cm.ToString("0.##") + " canvas=" + _w + "x" + _h +
               " scale=" + _scale.ToString("F4") + " step=" + StepYuan.ToString("0.##") +
               " status=" + _status +
               " corner=" + Location.X + "," + Location.Y;
    }

    // reports the shake offset and where the two text layers actually land, so
    // "the text shakes with the character" can be checked numerically
    public string ShakeReport() {
        double panelCx = (_fx[1] + _fx[2]) / 2 + _shakeX;
        double panelCy = (_fy[1] + _fy[2]) / 2 + _shakeY;
        string f = "none";
        if (_floaters.Count > 0) {
            Floater fl = _floaters[_floaters.Count - 1];
            double t = fl.T / fl.Dur;
            float em = (float)Math.Max(13.0, 34.0 * _scale);
            f = "(" + (fl.X + (int)Math.Round(fl.Jitter * Math.Sin(t * 9)) + (int)Math.Round(_shakeX)) +
                "," + (fl.Y - (int)Math.Round(t * em * 2.7) + (int)Math.Round(_shakeY)) + ")";
        }
        return "shake=(" + _shakeX.ToString("F1") + "," + _shakeY.ToString("F1") + ")" +
               " screenText=(" + panelCx.ToString("F1") + "," + panelCy.ToString("F1") + ")" +
               " floater=" + f;
    }

    public bool ConnectedFlag { get { return _connected; } }
    public double RealBalance { get { return _realBal; } }
    public double PendingCount { get { return _pending; } }
    public string BookedAtText { get { return double.IsNaN(_bookedAt) ? "--" : _bookedAt.ToString("0.00", CultureInfo.InvariantCulture); } }
    public string DemoLeftText { get { return _demoLeft.ToString(CultureInfo.InvariantCulture); } }
    public string CueGapText { get { return CueGapSec.ToString("0.#", CultureInfo.InvariantCulture); } }
    public int FloaterCountPublic { get { return _floaters.Count; } }
    public int HeartsPublic { get { return _hearts.Count; } }
    // clears in-flight animation state so self-test scenarios stay independent
    public void ResetDemoForTest() {
        _hits.Clear(); _floaters.Clear(); _pendingStep = 0; _demoLeft = 0; _dueGap = 0;
        // _pending has to go as well: leaving a queue of owed cents behind made every
        // scenario after a spending test keep firing cues of its own (the animation
        // tail check then measured those instead of the animation it created).
        _pending = 0;
        // Top-up state has to be reset too. Leaving _creditPending set made a
        // later snap re-book it (30.00 + 0.01 = 30.01) and every scenario after
        // that was off by a cent.
        _creditPending = 0; _cueGrace = 0;
        _rices.Clear(); _rice = null; _riceGrab = null;
        _hearts.Clear();
        // _realBal has to be cleared as well, otherwise the next reading in a
        // scenario looks like a FIRST reading and is believed outright instead of
        // being compared against the previous one - which silently skipped the
        // whole top-up detection.
        _realBal = double.NaN;
    }
    public double StepValue { get { return StepYuan; } }
    public string LastCueText {
        get { return _lastCueAmount > 0 ? "-" + _lastCueAmount.ToString("0.####", CultureInfo.InvariantCulture) : "(none)"; }
    }
    public void ApplyBalancePublic(double bal, bool snap) { ApplyBalance(bal, snap); }
    // --topup turns this on for the regression scenario so the balance branch it
    // took is visible in pet.log; a screenshot cannot show which branch ran.
    static bool DiagBalance = false;
    // Multi-bowl scenario: every top-up drops its OWN bowl, and delivering one pays
    // out only that bowl's amount. Run by --topup.
    public void RunMultiBowlTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("multi-bowl (offline)");
        // Bounce tiering is driven purely by drop height, so state it explicitly.
        Console.WriteLine("  bounce tiers     : 30px->" + BouncesForDrop(30) +
                          "  150px->" + BouncesForDrop(150) +
                          "  400px->" + BouncesForDrop(400) +
                          "  1200px->" + BouncesForDrop(1200) +
                          "  (want 0/1/2/3)");
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);

        // Two separate recharges -> two bowls, each carrying its own amount.
        ApplyBalancePublic(33.00, false);
        ApplyBalancePublic(35.00, false);
        Console.WriteLine("  two recharges    : bowls=" + _rices.Count + " (want 2)" +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  printed=" + DrawnText + " (must still be 30.00)");
        PumpTicks(150);                      // let both settle
        Console.WriteLine("  settled          : " + RiceReport());

        // Collision volume: the two bowls must not sit on top of each other.
        double dist = -1;
        if (_rices.Count >= 2) {
            double ddx = _rices[1].X - _rices[0].X, ddy = _rices[1].Y - _rices[0].Y;
            dist = Math.Sqrt(ddx * ddx + ddy * ddy);
        }
        double need = _rices.Count >= 2 ? _rices[0].R + _rices[1].R : 0;
        Console.WriteLine("  collision volume : distance=" + dist.ToString("0") +
                          "  need>=" + need.ToString("0") +
                          "  " + (dist >= need - 1 ? "OK - not stacked" : "FAIL - overlapping"));

        // Deliver one of them only.
        double owedBefore = _creditPending;
        string printedBefore = DrawnText;
        OnRiceFed(_rices[0]);
        Console.WriteLine("  fed one          : printed=" + DrawnText +
                          "  (want 33.00) was=" + printedBefore +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          " (want 2.00, was " + owedBefore.ToString("0.00") + ")" +
                          "  bowlsLeft=" + _rices.Count);

        // Deliver the second: it must add only its own remaining amount.
        PumpTicks(50);                       // let the first finish fading out
        if (_rices.Count > 0) OnRiceFed(_rices[0]);
        Console.WriteLine("  fed the other    : printed=" + DrawnText +
                          "  (want 35.00)  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  bowlsLeft=" + _rices.Count);
        PumpTicks(50);                       // let that one fade out too
        Console.WriteLine("  bowls cleaned up : bowlsLeft=" + _rices.Count + " (want 0)");
        Console.WriteLine("  verdict: " +
            (Math.Abs(DrawnBalance - 35.00) < 0.005 && _rices.Count == 0
                ? "OK - one bowl per top-up, each pays its own amount"
                : "FAIL - printed=" + DrawnText + " bowlsLeft=" + _rices.Count));
        ResetDemoForTest();
    }

    // Size change while a bowl is on screen: the window must stay full-screen and the
    // girl must stay visible. Regression for "change the size and the girl vanishes",
    // which happened because SnapToCorner dragged the screen-sized window back to a
    // 454px corner.
    public void RunResizeWithBowlTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("resize while a bowl is out (offline)");
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);
        Rectangle vsFull = SystemInformation.VirtualScreen;
        int g1 = ClientSize.Width, g2 = ClientSize.Height;
        StartCredit(3.00);
        PumpTicks(20);
        int g3 = ClientSize.Width, g4 = ClientSize.Height;
        Console.WriteLine("  bowl out         : full=" + _fullScreen +
                          " off=" + _offX + "," + _offY +
                          " client=" + g3 + "x" + g4 +
                          " canvas=" + (_canvas == null ? 0 : _canvas.Width) + "x" + (_canvas == null ? 0 : _canvas.Height));
        // THE anti-flash assertion: the window must not have changed size at all when a
        // bowl appeared. A resize is what flashed the girl to the top-left for ~60ms.
        Console.WriteLine("  window unchanged : " + (g1 == g3 && g2 == g4) +
                          "  (want True; " + g1 + "x" + g2 + " -> " + g3 + "x" + g4 + ")");
        Console.WriteLine("  canvas is screen : " + ((_canvas != null && _canvas.Width == vsFull.Width && _canvas.Height == vsFull.Height) ? "OK" : "FAIL"));
        SetPixelSize(624);                    // the size menu, with a bowl on screen
        PumpTicks(4);
        Console.WriteLine("  after resize 624 : full=" + _fullScreen +
                          " off=" + _offX + "," + _offY +
                          " client=" + ClientSize.Width + "x" + ClientSize.Height);
        bool stillFull = ClientSize.Width == vsFull.Width && ClientSize.Height == vsFull.Height;
        bool girlVisible = _offY > 0 && _offY + _h <= ClientSize.Height;
        Console.WriteLine("  verdict: " +
            (stillFull && girlVisible && g1 == g3 && _rices.Count == 1
                ? "OK - window never resizes, girl stays on screen"
                : "FAIL - stillFull=" + stillFull + " girlVisible=" + girlVisible +
                  " resized=" + (g1 != g3) + " bowls=" + _rices.Count));
        SetPixelSize(454);
        ResetDemoForTest();
    }
    // Regression for the feeding pause: after a bowl is delivered there must be a
    // quiet window before the spending animation starts. Without it a rehearsal's
    // invented credit is re-booked as debt by the next poll and the girl starts
    // losing health the very instant the hearts appear, which ruins a demonstration.
    public void RunFeedGraceTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("feed grace (offline)");
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);
        ApplyBalancePublic(33.00, false);         // a recharge arrives
        PumpTicks(30);
        string before = DrawnText;

        // Deliver the bowl, then hand the balance straight back to the cloud figure,
        // which books the same amount again as debt - exactly the demonstration case.
        FeedRiceForShot();
        string afterFed = DrawnText;
        ApplyBalancePublic(30.00, false);
        double pendAfterPoll = _pending;

        PumpTicks(45);                            // 1.5s: still inside the 2s pause
        string at1_5s = DrawnText;
        PumpTicks(30);                            // 2.5s: the pause is over
        string at2_5s = DrawnText;

        Console.WriteLine("  fed              : " + before + " -> " + afterFed +
                          " (want 33.00)  debtBooked=" + pendAfterPoll.ToString("0.00"));
        Console.WriteLine("  at 1.5s          : " + at1_5s + " (must still be 33.00)");
        Console.WriteLine("  at 2.5s          : " + at2_5s + " (must have started falling)");
        bool held = at1_5s == "33.00";
        bool started = at2_5s != "33.00";
        Console.WriteLine("  verdict: " +
            (afterFed == "33.00" && held && started
                ? "OK - nothing is deducted for " + FeedGraceSec.ToString("0.#") + "s after feeding"
                : "FAIL - held=" + held + " started=" + started +
                  " fed=" + afterFed + " at1.5=" + at1_5s + " at2.5=" + at2_5s));
        ResetDemoForTest();
    }

    // Regression for "drag the girl, let go, she no longer returns to the corner".
    // That broke because SnapToCorner() guarded on the _fullScreen flag, which is only
    // refreshed by SyncWindowModeInternal and could still read true with no bowl out.
    public void RunSnapBackTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("grab + snap-back (offline)");
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);

        // 1) Grab arithmetic - this is what teleported the bowl to the top of the
        //    screen. Client coords == screen coords, so the offset is mouse minus the
        //    bowl's centre; adding _offY made it ~1000 too big.
        StartCredit(3.00);
        PumpTicks(4);
        if (_rices.Count > 0 && _riceArt != null) {
            Rice rb = _rices[0];
            Rice got = BowlAt((int)rb.X, (int)rb.Y);
            // Simulate what OnMouseDown records, then where the bowl goes on the first
            // mouse move to a point one pixel away: it must move by one pixel, not jump.
            double grabX = rb.X - rb.X, grabY = rb.Y - rb.Y;   // mouse exactly on centre
            double movedX = (rb.X + 1) - grabX, movedY = (rb.Y + 1) - grabY;
            Console.WriteLine("  grab pickup      : bowlAt=" + (got == rb) + " (want True)" +
                              "  firstMoveDelta=" + (int)(movedX - rb.X) + "," + (int)(movedY - rb.Y) +
                              " (want 1,1)");
        }
        // 2) Snap-back WITH a bowl still lying on the floor. This is the case the user
        //    hit: an old guard returned early whenever _rices.Count > 0, so after a
        //    bowl dropped the girl stayed wherever she was released. The bowl must not
        //    move either - it lives in screen coordinates, the widget offset does not
        //    apply to it. (The bowl from step 1 is deliberately left in play; an earlier
        //    version of this test reset it away and so encoded the bug.)
        Rectangle vsS = SystemInformation.VirtualScreen;
        Rectangle waS = Screen.PrimaryScreen.WorkingArea;
        int homeX = waS.Left - vsS.Left, homeY = Math.Max(0, waS.Bottom - vsS.Top - _h);
        int guard = 0;
        PumpTicks(120);                        // let the bowl settle first
        Rice bowl = _rices.Count > 0 ? _rices[0] : null;
        double bowlX = bowl != null ? bowl.X : 0, bowlY = bowl != null ? bowl.Y : 0;
        _offX = 400; _offY = 300;
        _snapping = false;
        SnapToCorner(false);
        bool startedWithBowl = _snapping;
        guard = 0;
        while (_snapping && guard++ < 240) PumpTicks(1);
        bool bowlStayed = bowl != null && Math.Abs(bowl.X - bowlX) < 1.0 && Math.Abs(bowl.Y - bowlY) < 1.0;
        Console.WriteLine("  bowl out, drag   : snapping=" + startedWithBowl +
                          "  off=" + _offX + "," + _offY +
                          "  home=" + homeX + "," + homeY +
                          "  bowls=" + _rices.Count +
                          "  bowlMoved=" + (bowl == null ? "n/a" : (!bowlStayed).ToString()));
        Console.WriteLine("  bowl out verdict : " +
            (startedWithBowl && _offX == homeX && _offY == homeY && bowlStayed
                ? "OK - she still flies home, and the bowl stays put"
                : "FAIL - started=" + startedWithBowl + " off=" + _offX + "," + _offY +
                  " bowlMoved=" + (bowl == null ? "n/a" : (!bowlStayed).ToString())));

        // 3) and the original case: no bowl out at all
        ResetDemoForTest();
        _offX = 400; _offY = 300;             // as if the user dropped her mid-screen
        _snapping = false;
        SnapToCorner(false);
        bool startedNoBowl = _snapping;
        guard = 0;
        while (_snapping && guard++ < 240) PumpTicks(1);
        Console.WriteLine("  no bowl, drag    : snapping=" + startedNoBowl +
                          "  off=" + _offX + "," + _offY +
                          "  home=" + homeX + "," + homeY);
        Console.WriteLine("  verdict: " +
            (startedNoBowl && _offX == homeX && _offY == homeY
                ? "OK - the girl flies back to the bottom-left corner"
                : "FAIL - started=" + startedNoBowl + " off=" + _offX + "," + _offY));
        ResetDemoForTest();
    }

    public void RunTestTopUp() {
        GoOffline();
        ResetDemoForTest();        ApplyBalancePublic(30.00, true);
        Console.WriteLine("test-top-up entry (offline)");
        Console.WriteLine("  before : printed=" + DrawnText + " real=" + _realBal.ToString("0.00"));
        double before = DrawnBalance;
        TestTopUp(3.00);
        Console.WriteLine("  click  : printed=" + DrawnText + " real=" + _realBal.ToString("0.00") +
                          " owedToPlayer=" + _creditPending.ToString("0.00") +
                          " bowl=" + (_rice != null ? "yes" : "no") +
                          "  (printed must still be " + before.ToString("0.00") + ")");
        PumpTicks(90);
        Console.WriteLine("  settled: printed=" + DrawnText +
                          " bounces=" + (_rice != null ? _rice.Bounces.ToString() : "-") +
                          " grounded=" + (_rice != null ? _rice.Grounded.ToString() : "-"));
        FeedRiceForShot();
        for (int i = 0; i < 90; i++) {
            PumpTicks(1);
        }
        Console.WriteLine("  fed    : printed=" + DrawnText +
                          " real=" + _realBal.ToString("0.00") +
                          "  (must be 33.00)  drift=" + (DrawnBalance - 33.00).ToString("0.00"));
        Console.WriteLine("  verdict: " +
            (Math.Abs(DrawnBalance - 33.00) < 0.005 ? "OK - 3 yuan rehearsal works end to end"
                                                   : "FAIL - printed is " + DrawnText));

        // Regression for the bug that made a delivered bowl credit NOTHING:
        // "test top-up" raises the LOCAL _realBal, and the next real poll brings it
        // back down to the true figure. The old spending-squeeze logic booked that
        // fall as spending and emptied the bowl, so feeding it added zero.
        Console.WriteLine();
        Console.WriteLine("rehearsal + real poll (regression)");
        DiagBalance = true;
        ResetDemoForTest();
        ApplyBalancePublic(13.39, true);
        Console.WriteLine("  after reset+snap : pending=" + _creditPending.ToString("0.00") +
                          " real=" + _realBal.ToString("0.00") +
                          " bookedBal=" + _bookedBal.ToString("0.00") +
                          " bookedAt=" + _bookedAt.ToString("0.00") +
                          " bowl=" + (_rice != null ? "yes" : "no"));
        TestTopUp(3.00);
        double owedAfterClick = _creditPending;
        Console.WriteLine("  after click      : pending=" + _creditPending.ToString("0.00") +
                          " real=" + _realBal.ToString("0.00") +
                          " bookedBal=" + _bookedBal.ToString("0.00") +
                          " bookedAt=" + _bookedAt.ToString("0.00"));
        ApplyBalancePublic(13.39, false);       // the real poll that used to kill it
        Console.WriteLine("  after real poll  : owedToPlayer=" + _creditPending.ToString("0.00") +
                          " (must stay " + owedAfterClick.ToString("0.00") + ")" +
                          "  real=" + _realBal.ToString("0.00") +
                          " bookedBal=" + _bookedBal.ToString("0.00") +
                          "  bowl=" + (_rice != null ? "yes" : "no"));
        PumpTicks(90);
        FeedRiceForShot();
        PumpTicks(4);
        Console.WriteLine("  fed              : printed=" + DrawnText +
                          " (must be 16.39)  real=" + _realBal.ToString("0.00"));
        Console.WriteLine("  verdict: " +
            (Math.Abs(DrawnBalance - 16.39) < 0.005
                ? "OK - rehearsal survives the real poll and pays out"
                : "FAIL - printed is " + DrawnText));

        // Leave the widget believing the live figure again.
        DiagBalance = false;
        ResetDemoForTest();
    }

    // screenshot / self-test hooks for the top-up bowl
    public void StartCreditPublic(double amount) { StartCredit(amount); }
    public Rice RiceState { get { return _rice; } }
    public Bitmap RiceArt { get { return _riceArt; } }
    public double RiceArtWidth { get { return _riceArt == null ? 0 : _riceArt.Width; } }
    public double RiceGrabX { get { return _riceGrabX; } }
    public double RiceGrabY { get { return _riceGrabY; } }
    public void OnRiceGrabbed(double dx, double dy) { _riceGrabX = dx; _riceGrabY = dy; }
    public void OnRiceDropped() {
        if (_rice != null && !_rice.Fed && RiceOnGirl(_rice)) OnRiceFed(_rice);
    }
    // Confirms the polished menu actually built: renderer type, top-level item
    // count and the size submenu captions. A menu cannot be captured with
    // SaveCanvas (it is a separate popup window), so assert it instead.
    public string MenuReport() {
        if (_menu == null) return "menu missing";
        StringBuilder sb = new StringBuilder();
        sb.Append("renderer=").Append(_menu.Renderer != null ? _menu.Renderer.GetType().Name : "null");
        sb.Append(" font=").Append(_menu.Font.Name);
        sb.Append(" items=").Append(_menu.Items.Count);
        if (_sizeItem != null) {
            sb.Append(" sizes=[");
            for (int i = 0; i < _sizeItem.DropDownItems.Count; i++) {
                if (i > 0) sb.Append(", ");
                sb.Append(_sizeItem.DropDownItems[i].Text);
            }
            sb.Append("]");
        }
        // The recharge rehearsal must be reachable from the menu, otherwise the
        // bowl can only be tested by actually paying.
        for (int i = 0; i < _menu.Items.Count; i++) {
            ToolStripMenuItem mi = _menu.Items[i] as ToolStripMenuItem;
            if (mi == null || mi.Text != S_TESTTOP) continue;
            sb.Append(" topupTest=[");
            for (int j = 0; j < mi.DropDownItems.Count; j++) {
                if (j > 0) sb.Append(", ");
                sb.Append(mi.DropDownItems[j].Text);
            }
            sb.Append("]");
        }
        // Sound submenu: the on/off row, a level header, the fixed steps, then
        // "custom". Reported with the tick state so a level row that cannot be
        // ticked shows up here instead of only being noticed by eye.
        if (_soundItem != null) {
            sb.Append(" sound=").Append(SoundMenuRows());
            sb.Append(" enabled=").Append(_soundEnabled).Append(" volume=").Append(_volume);
        }
        return sb.ToString();
    }

    // The rows as one line, e.g. "[sound-on*, ---, level, mute (0 %), 25 %, 50 %*]",
    // with a * on the ticked rows. Shared by the menu report and the sound test.
    string SoundMenuRows() {
        if (_soundItem == null) return "none";
        StringBuilder sb = new StringBuilder("[");
        for (int j = 0; j < _soundItem.DropDownItems.Count; j++) {
            if (j > 0) sb.Append(", ");
            ToolStripItem it = _soundItem.DropDownItems[j];
            ToolStripMenuItem mi = it as ToolStripMenuItem;
            sb.Append(it is ToolStripSeparator ? "---" : it.Text);
            if (mi != null && mi.Checked) sb.Append("*");
        }
        return sb.Append("]").ToString();
    }
    bool SoundRowChecked(string text) {
        if (_soundItem == null) return false;
        foreach (ToolStripItem it in _soundItem.DropDownItems) {
            ToolStripMenuItem mi = it as ToolStripMenuItem;
            if (mi != null && mi.Text == text) return mi.Checked;
        }
        return false;
    }
    static string PoolVolumeText(SoundPool p) {
        if (p == null) return "absent";
        if (p.Failed) return "failed";
        return p.VolumePercent.ToString(CultureInfo.InvariantCulture) + "%";
    }
    int LivePoolCount {
        get {
            int n = 0;
            if (_sound != null && !_sound.Failed) n++;
            if (_feedSound != null && !_feedSound.Failed) n++;
            return n;
        }
    }
    static int PoolVolume(SoundPool p) { return p == null || p.Failed ? -1 : p.VolumePercent; }

    // The sound rows have to reach the players, and the menu has to show the
    // state back. Both are easy to get wrong in a way nothing else notices: the
    // ticks are computed from _volume/_soundEnabled, so a setting that never
    // reached MCI would still look right.
    public void RunSoundTest() {
        Console.WriteLine("sound and volume");
        int before = _volume;
        bool wasOn = _soundEnabled;
        Console.WriteLine("  players: hit=" + PoolVolumeText(_sound) + " feed=" + PoolVolumeText(_feedSound) +
                          "  players live=" + LivePoolCount);
        SetVolumePercent(75);
        RefreshMenuChecks();
        bool rows75 = SoundRowChecked(S_SOUNDON) && SoundRowChecked("75 %") && !SoundRowChecked(S_MUTE0);
        bool pools75 = PoolVolume(_sound) == 75 && PoolVolume(_feedSound) == 75;
        Console.WriteLine("  set 75 %: " + SoundMenuRows());
        Console.WriteLine("  set 75 %: rows ok=" + rows75 + " pool=" + PoolVolumeText(_sound) +
                          "/" + PoolVolumeText(_feedSound) + "  verdict: " +
                          (rows75 && pools75 && LivePoolCount > 0 ? "OK" : "FAIL"));

        SetSoundEnabled(false);
        RefreshMenuChecks();
        bool muteOk = !_soundEnabled && !_soundWanted && !SoundRowChecked(S_SOUNDON) && !SoundRowChecked(S_MUTE0);
        Console.WriteLine("  muted: " + SoundMenuRows());
        Console.WriteLine("  muted: enabled=" + _soundEnabled + " wanted=" + _soundWanted +
                          "  verdict: " + (muteOk ? "OK" : "FAIL"));

        SetVolumePercent(0);
        RefreshMenuChecks();
        bool zeroOk = _volume == 0 && !_soundEnabled && !_soundWanted &&
                      SoundRowChecked(S_MUTE0) && !SoundRowChecked(S_SOUNDON);
        Console.WriteLine("  volume 0 %: " + SoundMenuRows());
        Console.WriteLine("  volume 0 %: volume=" + _volume + " enabled=" + _soundEnabled +
                          "  verdict: " + (zeroOk ? "OK" : "FAIL"));

        // and back, so a --topup run leaves nothing behind (nothing is written
        // anyway: diagnostic runs are save-disabled)
        SetVolumePercent(before);
        if (!wasOn) SetSoundEnabled(false);
        RefreshMenuChecks();
        Console.WriteLine("  restored: volume=" + _volume + " enabled=" + _soundEnabled +
                          "  rows " + SoundMenuRows());
    }

    // ------------------------------------------------------------- perf ---
    // Where the frame budget goes. A full frame redraws a SCREEN-SIZED canvas and
    // pushes it through UpdateLayeredWindow, so these numbers matter before any
    // "make it smoother" change: measure, do not guess.
    public void PerfReport() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("perf (offline): canvas=" + _canvas.Width + "x" + _canvas.Height +
                          " widget=" + _w + "x" + _h + " off=" + _offX + "," + _offY +
                          "  frame budget " + _timer.Interval + " ms");
        int n = 30;
        Stopwatch sw = Stopwatch.StartNew();

        _dirty = true; RenderToCanvas();
        _perfPhases = true;
        ResetPhases();
        sw.Restart(); for (int i = 0; i < n; i++) { _dirty = true; RenderToCanvas(); }
        Console.WriteLine("  RenderToCanvas  : " + (sw.Elapsed.TotalMilliseconds / n).ToString("0.00") + " ms");
        Console.WriteLine(PhaseReport(n));
        _perfPhases = false;

        sw.Restart();
        for (int i = 0; i < n; i++) { _dirty = true; RenderToCanvas(); PushLayer(); }
        Console.WriteLine("  PushLayer       : " +
                          (sw.Elapsed.TotalMilliseconds / n).ToString("0.00") + " ms (nothing changed: skipped)");

        sw.Restart();
        for (int i = 0; i < n; i++) { _dirty = true; RenderToCanvas(); PushLayer(); }
        double idleFrame = sw.Elapsed.TotalMilliseconds / n;
        Console.WriteLine("  idle frame      : " + idleFrame.ToString("0.00") + " ms" +
                          "  (" + (idleFrame / _timer.Interval * 100).ToString("0") + " % of the budget)");
        _offX += 1;                                              // one pixel of drag
        sw.Restart();
        for (int i = 0; i < n; i++) { _offX += 1; _dirty = true; RenderToCanvas(); PushLayer(); }
        double dragFrame = sw.Elapsed.TotalMilliseconds / n;
        Console.WriteLine("  drag frame      : " + dragFrame.ToString("0.00") + " ms" +
                          "  (" + (dragFrame / _timer.Interval * 100).ToString("0") + " % of the budget)");
        SnapToCorner(true);
        RenderToCanvas();
        PushLayer();

        // With a bowl out the girl snapshot runs every frame, so time it separately:
        // it used to allocate a canvas-sized bitmap and scan every canvas pixel.
        sw.Restart(); for (int i = 0; i < n; i++) SnapshotGirl(0, _offY);
        double snap = sw.Elapsed.TotalMilliseconds / n;
        Console.WriteLine("  SnapshotGirl    : " + snap.ToString("0.00") + " ms/call" +
                          "  (runs every frame while a bowl is out)");

        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);
        StartCredit(5.00);
        PumpTicks(2);
        sw.Restart(); for (int i = 0; i < n; i++) PumpTicks(1);
        double fallFrame = sw.Elapsed.TotalMilliseconds / n;
        Console.WriteLine("  bowl falling    : " + fallFrame.ToString("0.00") + " ms/tick" +
                          "  (" + (fallFrame / _timer.Interval * 100).ToString("0") + " % of the budget)");

        // What the mouse-drag path really costs per animation frame now that
        // OnMouseMove only marks the widget dirty (it used to repaint the whole
        // screen-sized window on every WM_MOUSEMOVE, ~195 ms per frame).
        int extra = 8;                             // moves arriving between two ticks
        sw.Restart();
        for (int i = 0; i < 15; i++) {
            for (int k = 0; k < extra; k++) { _offX += 1; _dirty = true; }
            PumpTicks(1);
        }
        double dragTick = sw.Elapsed.TotalMilliseconds / 15;
        Console.WriteLine("  drag " + extra + " moves + 1 tick: " + dragTick.ToString("0.00") + " ms/tick" +
                          "  (" + (dragTick / _timer.Interval * 100).ToString("0") +
                          " % of the budget; over 100 % means the animation stutters)");
        ResetDemoForTest();
        SnapToCorner(true);
        RenderToCanvas();
        PushLayer();
    }

    // ------------------------------------------------------- push self-check ---
    // Compares screen pixels, not canvas pixels: the question is whether the two
    // ways of feeding UpdateLayeredWindow really put the same thing on the screen,
    // and whether a dirty-rect push ever leaves stale pixels behind. The desktop
    // behind the window is NOT static on this machine (the DSH page animates), so
    // only pixels the canvas paints fully opaque are compared.
    public void UlwCheckReport() {
        GoOffline();
        _noNetwork = true;
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);
        StartCredit(5.00);
        MakeTick(StepYuan, true);              // shake + red tint + a floating number
        if (_hearts.Count == 0) {              // and a couple of hearts
            for (int i = 0; i < 2; i++) {
                Floater f = new Floater();
                f.X = _headX + _offX + i * 22; f.Y = (int)(_h * 0.20) + _offY;
                f.T = 0.05 + i * 0.05; f.Dur = 1.2; f.HeartPhase = i * 1.7; f.HeartSize = 26;
                _hearts.Add(f);
            }
        }
        if (_rices.Count > 0) { _rices[0].X = 700; _rices[0].Y = 950; }
        RenderToCanvas();

        // The reference is the CANVAS, not the other push path: the question is
        // whether the screen shows what the canvas holds.
        _ulwBlt = false; _forceFullFill = true; PushLayer(); Thread.Sleep(40);
        Bitmap a = GrabScreenCanvas();
        Console.WriteLine("  HBITMAP path vs canvas      : " + CompareScreenToCanvas(a) +
                          "   (want diff=0)");
        a.Dispose();

        _ulwBlt = true; _forceFullFill = true; PushLayer(); Thread.Sleep(40);
        Bitmap b = GrabScreenCanvas();
        Console.WriteLine("  DIB path (full) vs canvas   : " + CompareScreenToCanvas(b) +
                          "   (want diff=0)");
        b.Dispose();

        // A run of frames with a MOVING bowl, then compare the screen with the canvas:
        // anything the erase steps or the push missed shows up here. This is what
        // caught the ghosting that a dirty-rect push left behind.
        double bx = _rices.Count > 0 ? _rices[0].X : 0, by = _rices.Count > 0 ? _rices[0].Y : 0;
        for (int i = 0; i < 3; i++) {
            if (_rices.Count > 0) { _rices[0].X = 620 + i * 210; _rices[0].Y = 980 - i * 90; }
            RenderToCanvas();
            PushLayer();
        }
        Thread.Sleep(40);
        Bitmap c = GrabScreenCanvas();
        Console.WriteLine("  moving bowl vs canvas       : " + CompareScreenToCanvas(c) +
                          "   (want diff=0: nothing left where the bowl used to be)");
        c.Dispose();
        if (_rices.Count > 0) { _rices[0].X = bx; _rices[0].Y = by; }

        // and the widget itself moving, which is the drag path
        _offX = 700; _offY = 400;
        RenderToCanvas(); PushLayer();
        _offX = 760; _offY = 470;
        RenderToCanvas(); PushLayer();
        Thread.Sleep(40);
        Bitmap e = GrabScreenCanvas();
        Console.WriteLine("  moving girl vs canvas       : " + CompareScreenToCanvas(e) +
                          "   (want diff=0: no trail behind her)");
        e.Dispose();

        ResetDemoForTest();
        SnapToCorner(true);
        RenderToCanvas();
        PushLayer();
    }

    // The widget is only repainted when something about it changed. If that test
    // misses the frame where an animation ENDS, the last drawn heart or damage
    // number stays on the canvas - and since nothing repaints it, it stays on
    // screen for good. This compares the widget's pixels before an animation with
    // the pixels after it has finished and gone.
    public void RunAnimationTailTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("animation tail (offline)");
        ResetDemoForTest();
        // Freeze everything that can change the widget behind this test's back: the
        // offline alert dot appears whenever _lastPollResult is non-empty and the
        // poller is disconnected, and that alone accounted for the first failure of
        // this check inside --topup (which polls before it gets here).
        _connected = false;
        _lastPollResult = "";
        SnapToCorner(true);
        _hits.Clear(); _floaters.Clear(); _hearts.Clear();
        ApplyBalancePublic(30.00, true);      // a fixed printed number for both shots
        RenderToCanvas();
        byte[] clean = WidgetPixels();

        // Deliberately NOT MakeTick: that also changes the printed number, and a new
        // number forces a repaint anyway - which would hide the very thing this test
        // is looking for. Shake, a floating number and hearts on their own must all
        // be erased when they finish.
        _hits.Add(new Hit());
        Floater fl = new Floater();
        fl.Text = "-0.01"; fl.X = _headX - 20; fl.Y = _headY; fl.Dur = 1.0; fl.Jitter = 6;
        _floaters.Add(fl);
        SpawnHearts(_headX + _offX, (int)(_h * 0.20) + _offY);
        Console.WriteLine("  animating: hits=" + _hits.Count + " floaters=" + _floaters.Count +
                          " hearts=" + _hearts.Count);
        int frames = 0;
        for (; frames < 300; frames++) {
            PumpTicks(1);
            if (_hits.Count == 0 && _floaters.Count == 0 && _hearts.Count == 0) break;
        }
        RenderToCanvas();
        byte[] after = WidgetPixels();

        int diff = 0, maxd = 0;
        Rectangle r = WidgetRect();
        int w = r.Width;
        int dx0 = int.MaxValue, dy0 = int.MaxValue, dx1 = -1, dy1 = -1;
        for (int i = 0; i < clean.Length && i < after.Length; i += 4) {
            int d = 0;
            for (int c = 0; c < 4; c++) {
                int e = Math.Abs(clean[i + c] - after[i + c]);
                if (e > d) d = e;
            }
            if (d > 0) {
                diff++;
                if (d > maxd) maxd = d;
                int px = (i / 4) % w, py = (i / 4) / w;
                if (px < dx0) dx0 = px; if (px > dx1) dx1 = px;
                if (py < dy0) dy0 = py; if (py > dy1) dy1 = py;
            }
        }
        Console.WriteLine("  after " + frames + " frames: hits=" + _hits.Count +
                          " floaters=" + _floaters.Count + " hearts=" + _hearts.Count +
                          "  widgetDiff=" + diff + " maxDelta=" + maxd + " of " + (clean.Length / 4) + " px" +
                          (diff > 0 ? "  bbox=" + dx0 + "," + dy0 + ".." + dx1 + "," + dy1 +
                                      " (canvas " + (dx0 + r.Left) + "," + (dy0 + r.Top) + ")" : ""));
        Console.WriteLine("  verdict: " + (diff == 0
            ? "OK - nothing is left over once the animation ends"
            : "FAIL - " + diff + " pixels of the finished animation are still on the canvas"));
        ResetDemoForTest();
    }

    Rectangle WidgetRect() {
        return Rectangle.Intersect(
            new Rectangle(_offX - 16, _offY - 96, _w + 32, _h + 112), CanvasRect());
    }

    byte[] WidgetPixels() {
        Rectangle r = WidgetRect();
        Buf b = new Buf(_canvas, r);
        try { return (byte[])b.P.Clone(); } finally { b.Dispose(); }
    }

    // A bowl lying on the girl erases its own rectangle before it is redrawn. If that
    // erase takes a bite out of the girl and the widget is NOT repainted afterwards
    // (the "nothing changed" fast path), the bite stays: the bowl appears to smear
    // her away while it is dragged across her. This parks a bowl on her, renders a
    // few frames, takes the bowl away and compares the widget with how it looked
    // before - any missing pixels are the smear.
    public void RunBowlOverGirlTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("bowl parked on the girl (offline)");
        ResetDemoForTest();
        _connected = false;
        _lastPollResult = "";
        SnapToCorner(true);
        _hits.Clear(); _floaters.Clear(); _hearts.Clear();
        ApplyBalancePublic(30.00, true);
        RenderToCanvas();
        byte[] clean = WidgetPixels();

        int gx, gy;
        if (!GirlSample(out gx, out gy)) {
            Console.WriteLine("  verdict: FAIL - no solid girl pixel to park the bowl on");
            ResetDemoForTest();
            return;
        }
        StartCredit(3.00);
        PumpTicks(2);
        if (_rices.Count == 0) {
            Console.WriteLine("  verdict: FAIL - no bowl to move");
            ResetDemoForTest();
            return;
        }
        Rice b = _rices[0];
        b.Dragging = true;
        b.Fed = false;

        // Drag it across her: each frame the bowl moves, so each frame erases the
        // rectangle it used to occupy - which is exactly where she is.
        int[] stepsX = new int[] { -60, -20, 20, 60, 0 };
        for (int i = 0; i < stepsX.Length; i++) {
            b.X = gx + stepsX[i];
            b.Y = gy - b.R + 10;
            RenderToCanvas();
            PushLayer();
        }
        int smearX = (int)b.X, smearY = (int)b.Y;
        // Evidence, grabbed from the whole screen so it can be compared with the
        // screen recording of the bug: the bowl must simply cover part of her, not
        // punch a rectangular hole through her.
        CaptureDesktop(Path.Combine(_baseDir, "_bowlgirl_over.png"));

        // Take the bowl away and let the scene settle, then compare.
        b.Dragging = false;
        _rices.Clear();
        _rice = null;
        for (int i = 0; i < 3; i++) { RenderToCanvas(); PushLayer(); }
        CaptureDesktop(Path.Combine(_baseDir, "_bowlgirl_after.png"));
        byte[] after = WidgetPixels();

        int diff = 0, maxd = 0;
        int dx0 = int.MaxValue, dy0 = int.MaxValue, dx1 = -1, dy1 = -1;
        int w = WidgetRect().Width;
        for (int i = 0; i < clean.Length && i < after.Length; i += 4) {
            int d = 0;
            for (int c = 0; c < 4; c++) {
                int e = Math.Abs(clean[i + c] - after[i + c]);
                if (e > d) d = e;
            }
            if (d > 0) {
                diff++;
                if (d > maxd) maxd = d;
                int px = (i / 4) % w, py = (i / 4) / w;
                if (px < dx0) dx0 = px; if (px > dx1) dx1 = px;
                if (py < dy0) dy0 = py; if (py > dy1) dy1 = py;
            }
        }
        Console.WriteLine("  bowl at " + smearX + "," + smearY + " over girl at " + gx + "," + gy +
                          "  girlDiff=" + diff + " maxDelta=" + maxd +
                          (diff > 0 ? "  bbox=" + dx0 + "," + dy0 + ".." + dx1 + "," + dy1 : ""));
        Console.WriteLine("  verdict: " + (diff == 0
            ? "OK - the girl is intact after a bowl was dragged across her"
            : "FAIL - " + diff + " pixels of the girl were erased by the bowl"));
        ResetDemoForTest();
    }

    // A top-up has to stay uncollected until the bowl is delivered - not just on the
    // poll that noticed it, but on every poll after it too. The balance stops moving
    // once the money is in, so the NEXT poll takes the ordinary debt path, and that
    // path used to compute a NEGATIVE debt (_bookedAt - bal, with the uncollected
    // top-up ignored) and "correct" the readout straight onto the live balance: the
    // number climbed on its own a few seconds after a recharge, and delivering the
    // bowl then pushed it ABOVE the real balance (user-reported after a real 20 yuan
    // recharge). This walks that exact sequence.
    public void RunTopUpHoldTest() {
        GoOffline();
        _noNetwork = true;
        Console.WriteLine("top-up held across polls (offline)");
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);
        Console.WriteLine("  live balance 30.00: printed=" + DrawnText);

        ApplyBalancePublic(40.00, false);          // the recharge lands
        bool frozenOnTopUp = Math.Abs(DrawnBalance - 30.00) < 1e-9;
        Console.WriteLine("  +10 lands        : printed=" + DrawnText +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  bowl=" + (_rices.Count > 0 ? "yes" : "no") +
                          "  (must still be 30.00)");

        // Every 2 seconds the poller reads the same, unchanged balance.
        for (int i = 0; i < 3; i++) {
            PumpTicks(6);
            ApplyBalancePublic(40.00, false);
        }
        bool stillFrozen = Math.Abs(DrawnBalance - 30.00) < 1e-9;
        Console.WriteLine("  +3 idle polls    : printed=" + DrawnText +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  (must still be 30.00 - the money is not collected yet)");

        FeedRiceForShot();
        PumpTicks(4);
        bool exact = Math.Abs(DrawnBalance - 40.00) < 1e-9;
        Console.WriteLine("  bowl delivered   : printed=" + DrawnText +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  (must be exactly 40.00 = the live balance)");

        // A second recharge, then ordinary spending: the shape of the real case that
        // was reported (20 yuan arriving as two 10 yuan credits).
        ApplyBalancePublic(50.00, false);
        bool frozen2 = Math.Abs(DrawnBalance - 40.00) < 1e-9;
        for (int i = 0; i < 3; i++) { PumpTicks(6); ApplyBalancePublic(50.00, false); }
        bool frozen3 = Math.Abs(DrawnBalance - 40.00) < 1e-9;
        FeedRiceForShot();
        PumpTicks(4);
        bool exact2 = Math.Abs(DrawnBalance - 50.00) < 1e-9;
        Console.WriteLine("  second +10       : printed=" + DrawnText +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  (must be exactly 50.00 = the live balance)");
        ApplyBalancePublic(49.95, false);
        // 400 ticks is ~13s: a delivery buys a 2s pause (FeedGraceSec), then each cent
        // takes another 0.2s. 60 ticks looked "stuck" because the grace period ate it.
        for (int i = 0; i < 400 && _pending > 0; i++) PumpTicks(1);
        bool spendOk = Math.Abs(DrawnBalance - 49.95) < 1e-9;
        Console.WriteLine("  spend 0.05       : printed=" + DrawnText +
                          "  (must be 49.95, one cent per cue)");
        Console.WriteLine("  verdict: " + (frozenOnTopUp && stillFrozen && exact && frozen2 && frozen3 && exact2 && spendOk
            ? "OK - a held top-up stays frozen and pays out exactly once"
            : "FAIL - frozenOnTopUp=" + frozenOnTopUp + " stillFrozen=" + stillFrozen +
              " exact=" + exact + " frozen2=" + frozen2 + " exact2=" + exact2 + " spendOk=" + spendOk));
        ResetDemoForTest();
    }

    Bitmap GrabScreenCanvas() {
        Rectangle r = CanvasRect();
        Bitmap b = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(r.Width, r.Height));
        }
        return b;
    }

    // Only FULLY opaque pixels: at alpha 255 the premultiplied copy is identical to
    // the canvas, so any difference at all is a real one. Pixels with partial alpha
    // composite with the desktop behind the window and are not part of this test.
    string CompareScreenToCanvas(Bitmap screen) {
        Buf cb = new Buf(_canvas), sb = new Buf(screen);
        try {
            byte[] cp = cb.P, sp = sb.P;
            int cs = cb.Stride, ss = sb.Stride;
            int solid = 0, diff = 0, maxd = 0, dx0 = int.MaxValue, dy0 = int.MaxValue, dx1 = -1, dy1 = -1;
            for (int y = 0; y < cb.H; y++) {
                int rc = y * cs, rs = y * ss;
                for (int x = 0; x < cb.W; x++) {
                    if (cp[rc + x * 4 + 3] != 255) continue;
                    solid++;
                    int d = 0;
                    for (int c = 0; c < 3; c++) {
                        int e = Math.Abs(cp[rc + x * 4 + c] - sp[rs + x * 4 + c]);
                        if (e > d) d = e;
                    }
                    if (d > 0) {
                        diff++;
                        if (d > maxd) maxd = d;
                        if (x < dx0) dx0 = x; if (x > dx1) dx1 = x;
                        if (y < dy0) dy0 = y; if (y > dy1) dy1 = y;
                        if (diff <= 4) {
                            Console.WriteLine("    sample " + x + "," + y +
                                "  canvas=" + cp[rc + x*4 + 2] + "," + cp[rc + x*4 + 1] + "," + cp[rc + x*4] +
                                "  screen=" + sp[rs + x*4 + 2] + "," + sp[rs + x*4 + 1] + "," + sp[rs + x*4]);
                        }
                    }
                }
            }
            return "solid=" + solid + " diff=" + diff + " maxDelta=" + maxd +
                   (diff > 0 ? " bbox=" + dx0 + "," + dy0 + ".." + dx1 + "," + dy1 : "");
        } finally { cb.Dispose(); sb.Dispose(); }
    }


    // ------------------------------------------------- menu appearance shots ---
    // Development-only helpers for --menushot. A dropdown is a separate popup
    // window, so the beautified menu can only be inspected by opening it for real
    // and grabbing that slice of the screen.

    public void SetVolumeForShot(int pct) { SetVolumePercent(pct); }
    // Diagnostic runs (--selftest/--shot/--topup/--simchain/--menushot/--iconshot)
    // move the size and the volume around; without this they would leave those
    // values in the user's state.ini.
    public void NoSaveForTest() { _noSave = true; }
    public Point MenuOrigin() { return new Point(240, 240); }

    public void OpenRootMenu(Point pt) {
        _menu.Show(pt);
        _menu.Items[0].Select();                  // show the hover styling
    }
    public void HoverItem(int index) {
        if (index < 0 || index >= _menu.Items.Count) return;
        _menu.Items[index].Select();
    }
    public void OpenSoundMenu() {
        _menu.Close();
        _menu.Show(MenuOrigin());
        _soundItem.ShowDropDown();
        HoverSoundLevel(2);
    }
    public void OpenSizeMenu() {
        _soundItem.DropDown.Close();
        _sizeItem.ShowDropDown();
    }
    // i-th fixed volume row (0 = mute, 1 = 25 %, ...), skipping the separator and
    // the header, exactly the way RefreshMenuChecks finds them.
    public void HoverSoundLevel(int i) {
        if (_soundItem == null) return;
        int idx = _soundItem.DropDownItems.IndexOf(_muteItem) + 3 + i;
        if (idx < 0 || idx >= _soundItem.DropDownItems.Count) return;
        _soundItem.DropDownItems[idx].Select();
    }
    public void CloseMenus() { _menu.Close(); }

    // Row metrics of every dropdown, printed after the shots so the popup size
    // can be compared against the sum of its rows instead of being guessed at
    // from a screenshot.
    public string MenuMetrics() {
        StringBuilder sb = new StringBuilder();
        RowMetrics(sb, "root", _menu, _menu.Items);
        if (_soundItem != null) RowMetrics(sb, "sound", _soundItem.DropDown, _soundItem.DropDownItems);
        if (_sizeItem != null) RowMetrics(sb, "size", _sizeItem.DropDown, _sizeItem.DropDownItems);
        return sb.ToString();
    }
    static void RowMetrics(StringBuilder sb, string name, Control c, ToolStripItemCollection items) {
        int sum = 0;
        sb.Append(name).Append(": cli=").Append(c.ClientSize.Width).Append("x").Append(c.ClientSize.Height);
        sb.Append(" rows=").Append(items.Count).Append(" [");
        for (int i = 0; i < items.Count; i++) {
            if (i > 0) sb.Append(",");
            sb.Append(items[i].Height);
            sum += items[i].Height;
        }
        sb.Append("] sum=").Append(sum);
        sb.Append(" content=").Append(items[0].ContentRectangle);
        if (items[0].Image != null) sb.Append(" pic=").Append(items[0].Image.Size);
        sb.Append("  ");
    }

    // Screen rectangle of every open dropdown, so the capture can be cropped.
    // PointToScreen, not Bounds: a submenu is parented to its owner popup and its
    // Bounds would then be client-relative.
    static Rectangle ScreenRect(Control c) {
        return new Rectangle(c.PointToScreen(Point.Empty), c.Size);
    }
    public Rectangle MenuBounds() {
        Rectangle r = _menu.Visible ? ScreenRect(_menu) : Rectangle.Empty;
        ToolStripDropDown[] drops = new ToolStripDropDown[] {
            _soundItem != null ? _soundItem.DropDown : null,
            _sizeItem != null ? _sizeItem.DropDown : null
        };
        foreach (ToolStripDropDown d in drops) {
            if (d == null || !d.Visible) continue;
            Rectangle dr = ScreenRect(d);
            r = r.IsEmpty ? dr : Rectangle.Union(r, dr);
        }
        return r;
    }

    public void CaptureRegion(string path, Rectangle r, int margin) {
        if (r.IsEmpty) { Console.WriteLine("capture: empty rect, skipped"); return; }
        r.Inflate(margin, margin);
        Rectangle vs = SystemInformation.VirtualScreen;
        r.Intersect(vs);
        if (r.Width <= 0 || r.Height <= 0) { Console.WriteLine("capture: off screen"); return; }
        try {
            using (Bitmap b = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb)) {
                using (Graphics g = Graphics.FromImage(b)) {
                    g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(r.Width, r.Height));
                }
                b.Save(path, ImageFormat.Png);
            }
            Console.WriteLine("capture -> " + Path.GetFileName(path) +
                              " (" + r.Width + "x" + r.Height + " at " + r.Left + "," + r.Top + ")");
        } catch (Exception ex) { Console.WriteLine("capture failed: " + ex.Message); }
    }
    // exercises the size presets without a mouse; returns "name=WxH" per preset
    public string SizePresetReport() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < PresetPx.Length; i++) {
            SetPixelSize(PresetPx[i]);
            sb.Append(SizeNames[i]).Append("=").Append(_w).Append("x").Append(_h);
            sb.Append(" ");
        }
        SetPixelSize(454);                 // back to the default (big cup)
        sb.Append("custom(700)= ");
        SetPixelSize(700);
        sb.Append(_w).Append("x").Append(_h);
        SetPixelSize(454);
        return sb.ToString();
    }
    // Forces the delivery step for --shot/--topup, without simulating a mouse drag.
    // It goes through OnRiceFed() on purpose: the tests must exercise the real
    // credit path, not a copy of it (a duplicated version is how the "number moves
    // before delivery" behaviour survived earlier testing).
    public void FeedRiceForShot() {
        if (_rice == null || _rice.Fed) return;
        OnRiceFed(_rice);
    }
    // The bowl lives in its own window, so the pet's own canvas can never show
    // it. Grabbing the desktop is the only honest check of where it falls.
    public void CaptureDesktop(string path) {
        try {
            Rectangle vs = SystemInformation.VirtualScreen;
            using (Bitmap b = new Bitmap(vs.Width, vs.Height, PixelFormat.Format32bppArgb)) {
                using (Graphics g = Graphics.FromImage(b)) {
                    g.CopyFromScreen(vs.Left, vs.Top, 0, 0, new Size(vs.Width, vs.Height));
                }
                b.Save(path, ImageFormat.Png);
            }
            Console.WriteLine("desktop shot -> " + Path.GetFileName(path) +
                              " (" + vs.Width + "x" + vs.Height + ")");
        } catch (Exception ex) { Console.WriteLine("desktop shot failed: " + ex.Message); }
    }

    // Dump the real canvas, downscaled, so the widget's placement can be checked
    // without guessing from a desktop grab.
    public void DumpCanvasScaled(string path) {
        if (_canvas == null) { Console.WriteLine("canvas dump: none"); return; }
        int tw = 640, th = Math.Max(1, _canvas.Height * tw / Math.Max(1, _canvas.Width));
        using (Bitmap b = new Bitmap(tw, th, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(b)) {
                g.Clear(Color.FromArgb(255, 30, 30, 40));       // so black-on-black shows
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(_canvas, new Rectangle(0, 0, tw, th));
            }
            b.Save(path, ImageFormat.Png);
        }
        Console.WriteLine("canvas dump -> " + Path.GetFileName(path) + " (" + tw + "x" + th + ")");
    }

    // First solid pixel of the girl, in canvas coordinates. Used by the self-test
    // to prove the menu gate and the bowl pickup actually agree with reality -
    // these were the two things that silently broke when the hit map outgrew the
    // widget, and a screenshot cannot check either of them.
    public bool GirlSample(out int cx, out int cy) {
        cx = 0; cy = 0;
        if (_hitMap == null || _hitW <= 0 || _hitH <= 0) return false;
        for (int y = 0; y < _hitH; y += 3) {
            int row = y * _hitW;
            for (int x = 0; x < _hitW; x += 3) {
                if (_hitMap[row + x] > 8) { cx = x; cy = y; return true; }
            }
        }
        return false;
    }
    public bool GirlSolidPublic(int cx, int cy) { return GirlPixelSolid(cx, cy); }
    public bool BowlHitPublic(int cx, int cy) { return BowlHit(cx, cy); }
    public int OffXPublic { get { return _offX; } }
    public int OffYPublic { get { return _offY; } }
    // Where the hit map's solid pixels actually are, and how many. Without this the
    // "menu opens on the bowl" failure is invisible.
    // What is actually painted at a canvas point? Distinguishes "the girl was
    // drawn there" from "something else was drawn there".
    public string CanvasProbe(int x, int y) {
        if (_canvas == null) return "no canvas";
        if (x < 0 || y < 0 || x >= _canvas.Width || y >= _canvas.Height) return "out of range";
        Color c = _canvas.GetPixel(x, y);
        int m = 0;
        if (_hitMap != null && x < _hitW && y < _hitH) m = _hitMap[y * _hitW + x];
        int cm2 = 0;
        if (_charHitMap != null && _charHitMap.Length == _canvas.Width * _canvas.Height)
            cm2 = _charHitMap[y * _canvas.Width + x];
        return "(" + x + "," + y + ") A=" + c.A + " RGB=" + c.R + "," + c.G + "," + c.B +
               " hit=" + m + " char=" + cm2;
    }

    public string HitMapReport() {        if (_hitMap == null) return "map=null";
        int n = 0, minY = int.MaxValue, maxY = -1, minX = int.MaxValue, maxX = -1;
        for (int y = 0; y < _hitH; y += 3) {
            int row = y * _hitW;
            for (int x = 0; x < _hitW; x += 3) {
                if (_hitMap[row + x] > 8) {
                    n++;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                }
            }
        }
        return "map=" + _hitW + "x" + _hitH + " solidSamples=" + n +
               " bbox=x" + minX + ".." + maxX + " y" + minY + ".." + maxY +
               " off=" + _offX + "," + _offY + " widget=" + _w + "x" + _h +
               " sprite=" + (_sprNormal == null ? "null" : _sprNormal.Width + "x" + _sprNormal.Height);
    }

    public string GeomReport() {
        return "win=" + Left + "," + Top + " client=" + ClientSize.Width + "x" + ClientSize.Height +
               " canvas=" + (_canvas == null ? 0 : _canvas.Width) + "x" + (_canvas == null ? 0 : _canvas.Height) +
               " off=" + _offX + "," + _offY +
               " widget=" + _w + "x" + _h + " full=" + _fullScreen;
    }

    public string RiceReport() {
        if (_rices.Count == 0) return "none";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < _rices.Count; i++) {
            Rice r = _rices[i];
            if (i > 0) sb.Append("  ");
            sb.Append("#").Append(i).Append("(").Append(r.Amount.ToString("0.00")).Append(")")
              .Append(" x=").Append(r.X.ToString("0")).Append(" y=").Append(r.Y.ToString("0"))
              .Append(" b=").Append(r.Bounces);
        }
        sb.Append(" hearts=").Append(_hearts.Count);
        return sb.ToString();
    }
    public int BowlCount { get { return _rices.Count; } }
    // Where the first bowl's base actually lands ON SCREEN (screen pixels), which is
    // what the eye checks. Printed by --shot after the bowl settles.
    public string BowlBottomOnScreen() {
        if (_rices.Count == 0) return "none";
        Rice r = _rices[0];
        // Screen == canvas (window origin is the screen origin), so no offset here.
        return "screenY=" + (r.Y + r.R).ToString("0") +
               " (screenBottom=" + SystemInformation.VirtualScreen.Bottom + ")" +
               " offY=" + _offY + " canvasH=" + (_canvas == null ? 0 : _canvas.Height);
    }
    // ------------------------------------------------------------------ top-up --
    // Offline scenario for --topup. Drives the whole recharge path without a
    // mouse: the server tops up, the readout must NOT follow, the bowl must
    // spawn, and only after the bowl is delivered may the number climb.
    // Returns a compact one-line report per step so the console shows the story.
    public void RunTopUpTest() {
        GoOffline();
        _noNetwork = true;
        Rectangle vs = SystemInformation.VirtualScreen;
        Console.WriteLine("top-up scenario (offline, deterministic)");
        ResetDemoForTest();
        ApplyBalancePublic(30.00, true);
        Console.WriteLine("  start            : printed=" + DrawnText +
                          " real=" + _realBal.ToString("0.00") +
                          " pending=" + _creditPending.ToString("0.00") +
                          " bowl=" + (_rice != null ? "yes" : "no"));

        // The server balance jumps up. Nothing on screen may move.
        ApplyBalancePublic(35.00, false);
        Console.WriteLine("  server -> 35.00  : printed=" + DrawnText +
                          " (must still be 30.00)" +
                          "  owedToPlayer=" + _creditPending.ToString("0.00") +
                          "  bowl=" + (_rice != null ? "yes" : "no") +
                          "  [diagnostics bookedBal=" + _bookedBal.ToString("0.0000") +
                          " bookedAt=" + _bookedAt.ToString("0.0000") +
                          " real=" + _realBal.ToString("0.0000") +
                          " testOffset=" + _testOffset.ToString("0.0000") +
                          " snap]");
        if (_rice != null) {
            bool onGirl = RiceOnGirl(_rice);
            Console.WriteLine("  bowl start       : x=" + _rice.X.ToString("0") +
                              " y=" + _rice.Y.ToString("0") + " canvas=" + _w + "x" + _h +
                              "  insideX=" + (_rice.X >= 0 && _rice.X <= _w) +
                              "  insideY=" + (_rice.Y >= 0 && _rice.Y <= _h) +
                              "  overlappingGirl=" + onGirl +
                              " (must be False, or a stray drag would deliver it)");
        }

        PumpTicks(30);       // one second of ticks: the bowl must fall, not the number
        Console.WriteLine("  after 1s of ticks: printed=" + DrawnText +
                          " (must still be 30.00)  bowls=" + _rices.Count +
                          "  " + RiceReport());

        PumpTicks(150);      // let it settle on the floor
        Console.WriteLine("  settled          : printed=" + DrawnText +
                          " (must still be 30.00)" +
                          "  " + RiceReport());

        // THE delivery test: move the bowl onto the girl and ask RiceOnGirl().
        // This is exactly what a drag-and-release does, so it catches the class of
        // bug where the hit map was sized/indexed in the wrong space and the bowl
        // was never accepted (delivery silently did nothing).
        PumpTicks(2);                     // make sure a girl snapshot exists
        bool farFirst = RiceOnGirl(_rice);
        // Put the bowl on a pixel that is ACTUALLY the girl, rather than guessing her
        // centre - the centre of her artwork is transparent (her face is off to one
        // side), which is why the earlier test kept reporting "not delivered".
        int sgx, sgy;
        bool haveGirlPixel = GirlSample(out sgx, out sgy);
        // Canvas == screen, so the girl's pixel is already in screen coordinates.
        double gx = sgx, gy = sgy;
        if (_rice != null) { _rice.X = gx; _rice.Y = gy; }
        int onGirlNow = RiceOnGirl(_rice) ? 1 : 0;
        int cwB = _canvas == null ? 0 : _canvas.Width;
        int boxHits = 0;
        if (_charHitMap != null && cwB > 0 && _rice != null && _riceArt != null) {
            int chB2 = _charHitMap.Length / cwB;
            double hwB = _riceArt.Width / 2.0;
            int bx0 = Math.Max(0, (int)(_rice.X - hwB - _offX)), bx1 = Math.Min(cwB - 1, (int)(_rice.X + hwB - _offX));
            int by0 = Math.Max(0, (int)(_rice.Y - hwB - _offY)), by1 = Math.Min(chB2 - 1, (int)(_rice.Y + hwB - _offY));
            for (int y = by0; y <= by1; y++) {
                int row = y * cwB;
                for (int x = bx0; x <= bx1; x++) if (_charHitMap[row + x] > 8) boxHits++;
            }
        }
        Console.WriteLine("  delivery test    : farAway=" + farFirst + " (want False)" +
                          "  onGirl=" + (onGirlNow == 1) + " (want True)" +
                          "  girlPixel=" + (haveGirlPixel ? sgx + "," + sgy : "none") +
                          "  solidInBox=" + boxHits);
        if (_rice != null) { _rice.X = vs.Right - _rice.R * 1.2; _rice.Y = vs.Bottom - _rice.R; }

        // Deliver it, exactly what a drag-and-release does, and check that the money
        // lands in ONE shot at that instant - not gradually, and not before.
        string beforeFed = DrawnText;
        FeedRiceForShot();
        Console.WriteLine("  fed              : hearts=" + _hearts.Count +
                          "  printed=" + DrawnText + " (must be 35.00 immediately)" +
                          "  was=" + beforeFed +
                          "  uptoWallet=" + _creditPending.ToString("0.00"));
        // Hearts are drawn straight into the canvas, so they must already be in screen
        // coordinates. When they were widget-relative they landed in the canvas's
        // top-left corner: the feed played its sound and paid out but showed nothing.
        if (_hearts.Count > 0) {
            int hx = _hearts[0].X, hy = _hearts[0].Y;
            bool nearGirl = hx >= _offX && hx <= _offX + _w && hy >= _offY - 60 && hy <= _offY + _h;
            Console.WriteLine("  heart position   : first=" + hx + "," + hy +
                              "  offY=" + _offY + "  nearGirl=" + nearGirl + " (want True)");
        }
        // The credit floater must read "+x.xx": MakeFloaterBitmap colours a leading
        // "+" green so the gain is visually distinct from the red damage numbers.
        {
            string ft = "";
            for (int i = _floaters.Count - 1; i >= 0; i--) {
                if (_floaters[i].Text.Length > 0) { ft = _floaters[i].Text; break; }
            }
            bool green = ft.Length > 0 && ft[0] == '+';
            Console.WriteLine("  gain floater     : '" + ft + "'  green=" + green + " (want True)");
        }

        // Nothing left to animate; a few ticks must not move it any further.
        PumpTicks(30);
        Console.WriteLine("  after 1s         : printed=" + DrawnText +
                          " (must still be 35.00 - no drift after the one-shot)" +
                          "  real=" + _realBal.ToString("0.00"));

        // A balance refresh must agree, not drift back.
        ApplyBalancePublic(35.00, false);
        PumpTicks(4);
        Console.WriteLine("  re-poll 35.00    : printed=" + DrawnText +
                          " (must be 35.00)" +
                          "  drift=" + (DrawnBalance - 35.00).ToString("0.00"));

        Console.WriteLine("  verdict: " +
            (Math.Abs(DrawnBalance - 35.00) < 0.005 ? "OK - readout tracks the top-up"
                                                    : "FAIL - readout is " + DrawnText));
    }

    // drives the real tick loop without the UI timer, for --simchain
    public void PumpTicks(int n) { for (int i = 0; i < n; i++) OnTickProbe(); }
    // tests must never talk to the network: that races with the simulated readings
    public void PollNowSyncPublic(bool snap) { PollNowSync(snap); }
    public void GoOffline() {
        _noNetwork = true;
        _pollWant = 0;
        try { _timer.Stop(); _poll.Stop(); } catch { }
    }
    public string StateText { get { return "real=" + _realBal.ToString("0.####") + " printed=" + _bookedBal.ToString("0.####") + " bookedAt=" + _bookedAt.ToString("0.####") + " pend=" + _pending.ToString("0.####") + " step=" + _pendingStep.ToString("0.####") + " gap=" + _dueGap.ToString("0.###") + " hits=" + _hits.Count + " floaters=" + _floaters.Count + " dt=" + (_timer.Interval/1000.0).ToString("0.###"); } }
    void OnTickProbe() { OnTick(); }
    public string DrawnText {
        get { return double.IsNaN(DrawnBalance) ? "--" : DrawnBalance.ToString("0.00", CultureInfo.InvariantCulture); }
    }

    // advance animation state without the timer, used by --shot
    public void BurnFrames(int n) {
        for (int i = 0; i < n; i++) {
            double dt = 0.033;
            for (int k = _hits.Count - 1; k >= 0; k--) { _hits[k].T += dt; if (_hits[k].Done) _hits.RemoveAt(k); }
            for (int k = _floaters.Count - 1; k >= 0; k--) { _floaters[k].T += dt; if (_floaters[k].Done) _floaters.RemoveAt(k); }
        }
        RenderToCanvas();
        PushLayer();
    }

    public void RunSelfTest(string baseDir) {
        PollNowSync(true);                // start from the live value
        MakeTick(StepYuan, false);
        for (int i = 0; i < 6; i++) OnTick();
        RenderToCanvas();
        SaveCanvas(Path.Combine(baseDir, "selftest.png"));
        Console.WriteLine("selftest.png written; connected=" + _connected +
                          " drawn=" + DrawnText + " lastPoll=" + _lastPollResult);
    }

    // Writes a PNG of the WIDGET (not the whole screen-sized window), on a gradient
    // so transparent areas are visible. The window is permanently screen-sized now,
    // so cropping to the widget keeps these artefacts the same size and usefulness
    // they had when the window was widget-sized.
    public void SaveCanvas(string path) {
        int cw2 = Math.Min(_w, _canvas.Width), ch2 = Math.Min(_h, _canvas.Height);
        int sx = Math.Max(0, Math.Min(_offX, _canvas.Width - cw2));
        int sy = Math.Max(0, Math.Min(_offY, _canvas.Height - ch2));
        using (Bitmap copy = new Bitmap(cw2, ch2, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(copy))
                g.DrawImage(_canvas, new Rectangle(0, 0, cw2, ch2), new Rectangle(sx, sy, cw2, ch2), GraphicsUnit.Pixel);
            using (Bitmap flat = new Bitmap(copy.Width, copy.Height)) {
                using (Graphics g = Graphics.FromImage(flat)) {
                    using (LinearGradientBrush lg = new LinearGradientBrush(
                            new Rectangle(0, 0, flat.Width, flat.Height),
                            Color.FromArgb(255, 28, 32, 46), Color.FromArgb(255, 62, 42, 58),
                            LinearGradientMode.ForwardDiagonal))
                        g.FillRectangle(lg, 0, 0, flat.Width, flat.Height);
                    g.DrawImageUnscaled(copy, 0, 0);
                }
                flat.Save(path, ImageFormat.Png);
            }
        }
    }
}
'@
}

# ------------------------------------------------------------------ startup --

$here = $PSScriptRoot
if (-not $here) { $here = (Get-Location).Path }

# Credentials: local override, then environment, then DSH's own credential store.
# Two shapes are supported:
#   * an sk- API Key   -> https://api.deepseek.com/user/balance  (Authorization: Bearer)
#   * a DSH account grant (deepseek-account-platform/default)
#                      -> <issuer>/api/v0/users/get_user_summary  (x-dsh-auth-token)
# The account grant is what a plain DSH install has: no sk- key required.
$keyFile = Join-Path $here 'apikey.txt'
if (-not $env:DSHPET_KEY -and (Test-Path $keyFile)) {
    $k = (Get-Content $keyFile -Raw).Trim()
    if ($k) { $env:DSHPET_KEY = $k }
}
if (-not $env:DSHPET_KEY -and -not $env:DSHPET_TOKEN) {
    $cred = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
    if (Test-Path $cred) {
        $raw = Get-Content $cred -Raw
        $m = [regex]::Match($raw, 'DEEPSEEK_API_KEY:\s*(\S+)')
        if ($m.Success) {
            $env:DSHPET_KEY = $m.Groups[1].Value
        } else {
            $token = $null
            $issuer = $null
            $inRecord = $false
            foreach ($line in ($raw -split "`r?`n")) {
                if ($line -match '^\s{2}deepseek-account-platform/default:\s*$') { $inRecord = $true; continue }
                if ($inRecord) {
                    if ($line -match '^\s{2}\S') { break }
                    $mt = [regex]::Match($line, '^\s+token:\s*(\S+)\s*$')
                    if ($mt.Success) { $token = $mt.Groups[1].Value }
                    $mi = [regex]::Match($line, '^\s+issuer:\s*(\S+)\s*$')
                    if ($mi.Success) { $issuer = $mi.Groups[1].Value }
                }
            }
            # Only an HTTPS issuer is accepted, and never one carrying a query,
            # credentials or a path fragment we did not expect.
            if ($token -and $issuer -match '^https://[A-Za-z0-9\.\-]+(:[0-9]+)?/?$') {
                $env:DSHPET_AUTH = 'account'
                $env:DSHPET_TOKEN = $token
                $env:DSHPET_API = ($issuer.TrimEnd('/') + '/api/v0/users/get_user_summary')
            }
        }
    }
}
if (-not $env:DSHPET_SPRITE) { $env:DSHPET_SPRITE = Join-Path $here 'sprite.png' }


try {
    [DshPet]::Run($here, $args)
} catch {
    $_ | Out-String | Set-Content (Join-Path $here 'error.log') -Encoding UTF8
    throw
}





























