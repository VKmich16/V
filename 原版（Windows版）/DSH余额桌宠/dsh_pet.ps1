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
public sealed class Buf : IDisposable {
    public readonly Bitmap Bmp;
    public readonly int W, H, Stride;
    public readonly byte[] P;
    readonly BitmapData _d;

    public Buf(Bitmap b) {
        Bmp = b; W = b.Width; H = b.Height;
        _d = b.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        Stride = _d.Stride;
        P = new byte[Stride * H];
        Marshal.Copy(_d.Scan0, P, 0, P.Length);
    }
    public void Flush() { Marshal.Copy(P, 0, _d.Scan0, P.Length); }
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
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst,
        ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDC);
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

    public SoundPool(string path, int slots, int volumePercent, string logPath) {
        _path = path; _slots = slots; _logPath = logPath;
        _alias = new string[slots]; _open = new bool[slots];
        try {
            // The ABSOLUTE path is what MCI accepts. It used to cd into the sound's
            // folder and open the bare file name, on the theory that a non-ASCII
            // path gets mangled - but a bare name fails outright with "file not
            // found" no matter what the working directory is, and the full-path
            // retry below never ran because the success test looked at the reply
            // buffer instead of the return code. Result: the cue could never play.
            for (int i = 0; i < slots; i++) {
                _alias[i] = "dsphpet" + i;
                Send("close " + _alias[i]);
                _open[i] = SendOk("open \"" + path + "\" type mpegvideo alias " + _alias[i]);
                if (_open[i]) Send("setaudio " + _alias[i] + " volume to " + volumePercent * 10);
            }
            if (!_open[0]) { Failed = true; Error = "cannot open " + path; }
        } catch (Exception ex) { Failed = true; Error = ex.Message; }
    }

    // plays on a free alias and returns its index, or -1 when nothing played
    public int Play() {
        if (Failed) return -1;
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

    Bitmap _flat, _sprNormal, _sprRed, _canvas;
    double _scale = 1.0;
    int _w, _h;
    double[] _fx, _fy;
    double _cm = 8.0;            // widget edge length in centimetres
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

    bool _drag; Point _dragStart, _winStart;
    bool _snapping; double _snapT; Point _snapFrom, _snapTo;
    byte[] _hitMap; int _hitW, _hitH;
    NotifyIcon _tray;
    ContextMenuStrip _menu;
    ToolStripMenuItem _sizeItem;
    int _demoLeft;                   // cues left in a rehearsal run
    double _demoAmount = 0.01;

    // current frame's shake offset, so the readout and the floating numbers move
    // together with the character
    double _shakeX, _shakeY;
    // hit sound: one MCI alias per concurrent cue
    SoundPool _sound;
    bool _soundEnabled = true;
    bool _soundWanted = true;
    volatile bool _noNetwork;        // set by the offline self-tests
    int _pollInFlight;               // only one balance request at a time
    double _bankedBal; bool _bankedSnap; bool _bankedValid;

    public DshPet(string baseDir, string[] args) {
        _baseDir = baseDir;
        _apiKey  = Get("DSHPET_KEY", "");
        _apiUrl  = Get("DSHPET_API", "https://api.deepseek.com/user/balance");
        _isAccount = Get("DSHPET_AUTH", "key") == "account";
        _token     = Get("DSHPET_TOKEN", "");
        Log("credentials: " + CredentialSource + ", endpoint=" + _apiUrl);
        _pollMs  = int.Parse(Get("DSHPET_POLL_MS", "2000"));
        _cm      = double.Parse(Get("DSHPET_CM", "8"), CultureInfo.InvariantCulture);
        _soundWanted = Get("DSHPET_SOUND", "1") != "0";

        string sprite = Get("DSHPET_SPRITE", Path.Combine(baseDir, "sprite.png"));
        if (!File.Exists(sprite)) throw new FileNotFoundException("sprite not found: " + sprite);
        _flat = new Bitmap(sprite);

        // hit sound (mp3) - opens a small pool of MCI aliases up front so the
        // very first cue has no lag and overlapping cues do not cut each other.
        // The path is built here from baseDir rather than handed over through
        // the environment: values crossing the PowerShell/C# boundary come back
        // ANSI-mangled when the folder name is not ASCII, while a path built in
        // this process stays correct.
        string sndPath = Path.Combine(baseDir, Get("DSHPET_SOUND_FILE", "hit.mp3"));
        if (_soundWanted && File.Exists(sndPath)) {
            int vol = int.Parse(Get("DSHPET_VOLUME", "80"));
            _sound = new SoundPool(sndPath, 4, vol, Path.Combine(baseDir, "pet.log"));
            if (_sound.Failed) Log("sound pool failed: " + _sound.Error);
            else Log("sound ready: " + sndPath + " volume=" + vol);
        } else if (_soundWanted) {
            Log("sound file missing: " + sndPath + " (hit sound disabled)");
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
        bool quietRun = Array.IndexOf(args, "--selftest") >= 0 || Array.IndexOf(args, "--shot") >= 0;
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

    void BuildMenu() {
        _menu = new ContextMenuStrip();

        ToolStripMenuItem refresh = new ToolStripMenuItem(S_REFRESH);
        refresh.Click += delegate { _pollWant = 2; };
        _menu.Items.Add(refresh);

        ToolStripMenuItem test = new ToolStripMenuItem(S_TEST);
        test.Click += delegate { DemoCharge(StepYuan); };
        _menu.Items.Add(test);

        // submenu: rehearse a bigger deduction to watch a run of consecutive cues
        ToolStripMenuItem demoItem = new ToolStripMenuItem(S_HELP);
        double[] demos = new double[] { 0.05, 0.1, 0.2, 0.5, 1.0 };
        foreach (double d in demos) {
            double v = d;
            ToolStripMenuItem it = new ToolStripMenuItem("-" + v.ToString("0.##", CultureInfo.InvariantCulture) +
                                                         "  (" + CueCount(v) + " \u6B21)");
            it.Click += delegate { DemoCharge(v); };
            demoItem.DropDownItems.Add(it);
        }
        demoItem.DropDownItems.Add(new ToolStripSeparator());
        ToolStripMenuItem demoCustom = new ToolStripMenuItem(S_CUSTOM);
        demoCustom.Click += delegate { AskDemo(); };
        demoItem.DropDownItems.Add(demoCustom);
        _menu.Items.Add(demoItem);

        _menu.Items.Add(new ToolStripSeparator());

        _sizeItem = new ToolStripMenuItem(S_SIZE);
        double[] sizes = new double[] { 1.5, 2.0, 3.0, 4.0, 6.0, 8.0 };
        foreach (double s in sizes) {
            double v = s;
            ToolStripMenuItem it = new ToolStripMenuItem(CmLabel(v));
            it.Click += delegate { SetCm(v); };
            _sizeItem.DropDownItems.Add(it);
        }
        _sizeItem.DropDownItems.Add(new ToolStripSeparator());
        ToolStripMenuItem sizeCustom = new ToolStripMenuItem(S_CUSTOM);
        sizeCustom.Click += delegate { AskCm(); };
        _sizeItem.DropDownItems.Add(sizeCustom);
        _menu.Items.Add(_sizeItem);

        _menu.Items.Add(new ToolStripSeparator());

        ToolStripMenuItem key = new ToolStripMenuItem(S_SETKEY);
        key.Click += delegate { AskKey(); };
        _menu.Items.Add(key);

        ToolStripMenuItem quit = new ToolStripMenuItem(S_QUIT);
        quit.Click += delegate { Quit(); };
        _menu.Items.Add(quit);

        _menu.Opening += delegate { RefreshMenuChecks(); };
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

    // ToolStrip check marks are reset on every open, so push them here.
    void RefreshMenuChecks() {
        string curSize = CmLabel(_cm);
        foreach (ToolStripItem it in _sizeItem.DropDownItems) {
            ToolStripMenuItem mi = it as ToolStripMenuItem;
            if (mi != null && mi.Text != S_CUSTOM) mi.Checked = (mi.Text == curSize);
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

    void SetCm(double v) {
        if (v < 0.8) v = 0.8;
        if (v > 40) v = 40;
        _cm = v;
        Relayout();
        SnapToCorner(true);               // keep it pinned to the corner
        SaveState();
        RenderToCanvas();
        PushLayer();
        Log("size set to " + CmLabel(v) + " -> " + _w + "x" + _h + " px");
    }

    void AskCm() {
        using (InputDialog d = new InputDialog(S_SIZET, S_SIZEP, "cm",
                                               _cm.ToString("0.##", CultureInfo.InvariantCulture))) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            double v;
            if (double.TryParse(d.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v > 0)
                SetCm(v);
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
        int px = (int)Math.Round(_cm / 2.54 * dpiY);
        if (px < 40) px = 40;
        _w = px; _h = px;
        ClientSize = new Size(_w, _h);
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
        _canvas = new Bitmap(_w, _h, PixelFormat.Format32bppArgb);

        // tablet screen quad in sprite pixels, from make_sprite.ps1 (min-area
        // rotated rectangle around the opaque black screen)
        double[] qx = new double[] { 550.3, 946.6, 980.9, 584.6 };
        double[] qy = new double[] { 706.3, 643.8, 861.4, 924.0 };
        _fx = new double[4]; _fy = new double[4];
        for (int i = 0; i < 4; i++) { _fx[i] = qx[i] * _scale; _fy[i] = qy[i] * _scale; }

        _headX = (int)(sw * 0.50 + sh * 0.17);
        _headY = (int)(sh * 0.36);
        // one text line high, so a fast run of numbers cascades without overlapping
        _floaterStep = (float)Math.Max(18.0, 34.0 * _scale * 1.7);
        _hitMap = null;
        _dirty = true;
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

    void SnapToCorner(bool immediate) {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Point target = new Point(wa.Left, wa.Bottom - _h);
        if (immediate) { Location = target; _snapping = false; return; }
        _snapFrom = Location;
        _snapTo = target;
        _snapT = 0;
        _snapping = true;
    }

    // --------------------------------------------------------------- state ---

    string StatePath { get { return Path.Combine(_baseDir, "state.ini"); } }
    string KeyPath { get { return Path.Combine(_baseDir, "apikey.txt"); } }

    void ReadState() {
        try {
            if (!File.Exists(StatePath)) return;
            foreach (string line in File.ReadAllLines(StatePath)) {
                int i = line.IndexOf('=');
                if (i <= 0) continue;
                string k = line.Substring(0, i).Trim(), v = line.Substring(i + 1).Trim();
                double d;
                if (k == "cm" && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d) && d >= 0.8)
                    _cm = d;
            }
        } catch { }
    }

    void SaveState() {
        try {
            File.WriteAllText(StatePath,
                "cm=" + _cm.ToString("0.##", CultureInfo.InvariantCulture) + "\r\n",
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

    void PushLayer() {
        if (_canvas == null || Handle == IntPtr.Zero) return;
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

    protected override void WndProc(ref Message m) {
        if (m.Msg == Native.WM_NCHITTEST) {
            int lp = (int)m.LParam;
            int x = (short)(lp & 0xFFFF), y = (short)((lp >> 16) & 0xFFFF);
            Point cp = PointToClient(new Point(x, y));
            bool solid = false;
            byte[] map = _hitMap;
            if (map != null && cp.X >= 0 && cp.Y >= 0 && cp.X < _hitW && cp.Y < _hitH)
                solid = map[cp.Y * _hitW + cp.X] > 8;
            m.Result = (IntPtr)(solid ? Native.HTCLIENT : Native.HTTRANSPARENT);
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) {
            _drag = true;
            _snapping = false;
            _dragStart = Cursor.Position;
            _winStart = Location;
        } else if (e.Button == MouseButtons.Right) {
            RefreshMenuChecks();
            _menu.Show(Cursor.Position);
        }
        base.OnMouseDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        if (_drag) {
            Point p = Cursor.Position;
            Location = new Point(_winStart.X + (p.X - _dragStart.X), _winStart.Y + (p.Y - _dragStart.Y));
            PushLayer();
        }
        base.OnMouseMove(e);
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        if (_drag) {
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

        Buf buf = new Buf(_canvas);
        try {
            byte[] p = buf.P;
            Array.Clear(p, 0, p.Length);

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

            BlitLayer(_sprNormal, p, buf.Stride, ox, oy, 1.0);
            for (int i = 0; i < _hits.Count; i++) {
                double pulse = _hits[i].Pulse;
                if (pulse > 0.01) {
                    // The hurt overlay is toned down as the widget grows: 60% of a
                    // 113px sprite is a readable flash, 60% of a 454px one would
                    // just be a red silhouette.
                    double maxTint = Math.Max(0.30, 0.64 - _scale * 0.75);
                    BlitLayer(_sprRed, p, buf.Stride, ox, oy, Math.Min(maxTint, maxTint * pulse));
                }
            }
            buf.Flush();
        } finally { buf.Dispose(); }

        DrawScreen();                                  // transparent screen + text only
        if (!_connected && _lastPollResult.Length > 0) DrawAlert();

        if (_floaters.Count > 0) {
            Buf b2 = new Buf(_canvas);
            try {
                for (int i = 0; i < _floaters.Count; i++) DrawFloater(_floaters[i], b2);
                b2.Flush();
            } finally { b2.Dispose(); }
        }

        Buf b3 = new Buf(_canvas);
        try { BuildHitMap(b3); } finally { b3.Dispose(); }
        _dirty = false;
    }

    void BlitLayer(Bitmap layer, byte[] dst, int dstStride, int ox, int oy, double alpha) {
        if (layer == null) return;
        Buf src = new Buf(layer);
        try {
            byte[] sp = src.P; int ss = src.Stride;
            for (int y = 0; y < src.H; y++) {
                int ty = y + oy;
                if (ty < 0 || ty >= _h) continue;
                int srow = y * ss, drow = ty * dstStride;
                for (int x = 0; x < src.W; x++) {
                    int tx = x + ox;
                    if (tx < 0 || tx >= _w) continue;
                    int si = srow + x * 4;
                    int sa = sp[si + 3];
                    if (sa == 0) continue;
                    Cs.Blend(dst, drow + tx * 4, sp[si + 2], sp[si + 1], sp[si], sa / 255.0 * alpha);
                }
            }
        } finally { src.Dispose(); }
    }

    void BuildHitMap(Buf buf) {
        if (_hitMap == null || _hitW != _w || _hitH != _h) {
            _hitMap = new byte[_w * _h]; _hitW = _w; _hitH = _h;
        }
        byte[] p = buf.P;
        for (int y = 0; y < _h; y++) {
            int row = y * _w, srow = y * buf.Stride;
            for (int x = 0; x < _w; x++) _hitMap[row + x] = p[srow + x * 4 + 3];
        }
    }

    // The panel bitmap carries ONLY the label and the number. The tablet screen
    // is an opaque black surface in the artwork, so the text is drawn light.
    Bitmap BuildPanel(int pw, int ph) {
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

                string txt = double.IsNaN(DrawnBalance)
                    ? "--"
                    : (DrawnBalance).ToString("0.00", CultureInfo.InvariantCulture);
                float fBal = H * 0.48f, fCur = H * 0.27f;
                using (Font fb = new Font("Arial", fBal, FontStyle.Bold, GraphicsUnit.Pixel))
                using (Font fc = new Font("Microsoft YaHei UI", fCur, FontStyle.Bold, GraphicsUnit.Pixel))
                using (Brush sh = new SolidBrush(Color.FromArgb(160, 0, 0, 0)))
                using (Brush bb = new SolidBrush(Color.FromArgb(255, 240, 246, 255)))
                using (Brush bc = new SolidBrush(Color.FromArgb(235, 158, 184, 230))) {
                    SizeF sb = g.MeasureString(txt, fb);
                    SizeF sc = g.MeasureString("\u00A5", fc);
                    float total = sb.Width + sc.Width;
                    float left = (W - total) / 2f;
                    float top = H * 0.44f;
                    g.DrawString("\u00A5", fc, sh, left + 1.5f, top + sb.Height * 0.24f + 1.5f);
                    g.DrawString(txt, fb, sh, left + sc.Width + 1.5f, top + 1.5f);
                    g.DrawString("\u00A5", fc, bc, left, top + sb.Height * 0.24f);
                    g.DrawString(txt, fb, bb, left + sc.Width, top);
                }
            }
        }
        return panel;
    }

    void DrawScreen() {
        float lw = (float)Math.Sqrt(Math.Pow(_fx[1] - _fx[0], 2) + Math.Pow(_fy[1] - _fy[0], 2));
        float lh = (float)Math.Sqrt(Math.Pow(_fx[3] - _fx[0], 2) + Math.Pow(_fy[3] - _fy[0], 2));
        if (lw < 8 || lh < 8) return;

        int pw = 520;
        int ph = (int)Math.Round(pw * (lh / lw));
        if (ph < 24) { ph = 24; pw = (int)Math.Round(ph * (lw / lh)); }

        Bitmap panel = BuildPanel(pw, ph);
        try {
            using (Graphics g = Graphics.FromImage(_canvas)) {
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                PointF[] dest = new PointF[3];
                dest[0] = new PointF((float)(_fx[0] + _shakeX), (float)(_fy[0] + _shakeY));
                dest[1] = new PointF((float)(_fx[1] + _shakeX), (float)(_fy[1] + _shakeY));
                dest[2] = new PointF((float)(_fx[3] + _shakeX), (float)(_fy[3] + _shakeY));
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
            float cx = (float)(_fx[1] + _fx[2]) / 2f + (float)_shakeX;
            float cy = (float)(_fy[1] + _fy[2]) / 2f + (float)(_h * 0.05) + (float)_shakeY;
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
                int x0 = fl.X + (int)Math.Round(fl.Jitter * Math.Sin(t * 9)) + (int)Math.Round(_shakeX);
                int y0 = fl.Y - (int)Math.Round(t * em * 2.7) + (int)Math.Round(_shakeY);
                for (int yy = 0; yy < h; yy++) {
                    int syy = (int)(yy / pop); if (syy >= src.H) break;
                    int ty = y0 + yy; if (ty < 0 || ty >= _h) continue;
                    for (int xx = 0; xx < w; xx++) {
                        int sxx = (int)(xx / pop); if (sxx >= src.W) break;
                        int tx = x0 + xx; if (tx < 0 || tx >= _w) continue;
                        int si = syy * ss + sxx * 4;
                        int sa = sp[si + 3]; if (sa == 0) continue;
                        Cs.Blend(p, ty * ds + tx * 4, sp[si + 2], sp[si + 1], sp[si], sa / 255.0 * alpha);
                    }
                }
            } finally { src.Dispose(); }
        } finally { bmp.Dispose(); }
    }

    Bitmap MakeFloaterBitmap(string text, float em) {
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
                    using (Pen outline = new Pen(Color.FromArgb(255, 92, 8, 8), em * 0.16f)) {
                        outline.LineJoin = LineJoin.Round;
                        g.DrawPath(outline, path);
                    }
                    using (Brush fill = new SolidBrush(Color.FromArgb(255, 255, 72, 60)))
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
                if (_snapT >= 1) { Location = _snapTo; _snapping = false; }
                else {
                    double e = 1 - Math.Pow(1 - _snapT, 3);
                    Location = new Point(
                        (int)Math.Round(_snapFrom.X + (_snapTo.X - _snapFrom.X) * e),
                        (int)Math.Round(_snapFrom.Y + (_snapTo.Y - _snapFrom.Y) * e));
                }
                PushLayer();
            }

            _lastCueAmount = 0;              // diagnostics: what fired this frame
            DrainBankedBalance();            // apply any reading that arrived

            if (_dueGap > 0) _dueGap -= dt;

            // The ONLY place the printed number moves: one cent per cue, never
            // more, and never without a cue. The debt is re-derived every time a
            // reading lands, so a reading arriving mid-cue can never strand it.
            double take = 0;
            if (_dueGap <= 0 && _pendingStep <= 0) {
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
            _realBal = bal;
            if (firstReading) {
                _bookedAt = bal;
                _bookedBal = bal;
                _pending = 0;
            }
            if (snap) {
                // "refresh now": believe the server exactly, drop rehearsals and
                // anything still queued
                _bookedAt = bal;
                _bookedBal = bal;
                _testOffset = 0;
                _pending = 0;
                _pendingStep = 0;
                _dueGap = 0;
            } else if (!firstReading) {
                // The whole difference becomes the debt. A cue already committed
                // but not yet charged counts as part of it, so it is subtracted
                // rather than overwritten - overwriting it is what used to make
                // the number move by less than one animation.
                double owed = Math.Round(_bookedAt - bal, 4);
                if (owed < -1e-9) {
                    // the server walked the balance back up (a correction, not a
                    // top-up): re-anchor so the debt is only what is uncharged
                    owed = _pending;
                    _bookedAt = Math.Round(bal + owed, 4);
                    _bookedBal = Math.Round(bal + owed, 4);
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
        try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { try { Native.SetProcessDPIAware(); } catch { } }

        bool selftest = Array.IndexOf(args, "--selftest") >= 0;
        bool shot = Array.IndexOf(args, "--shot") >= 0;
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        DshPet pet = new DshPet(baseDir, args);

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
                Application.Exit();
            };
            shotTimer.Start();
            Application.Run(pet);
            return;
        }

        if (selftest) {
            Console.WriteLine("diag: " + pet.Diag());
            pet.GoOffline();                  // deterministic: no background poll
            pet.RunSelfTest(baseDir);
            Application.Exit();
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
    // clears in-flight animation state so self-test scenarios stay independent
    public void ResetDemoForTest() {
        _hits.Clear(); _floaters.Clear(); _pendingStep = 0; _demoLeft = 0; _dueGap = 0;
    }
    public double StepValue { get { return StepYuan; } }
    public string LastCueText {
        get { return _lastCueAmount > 0 ? "-" + _lastCueAmount.ToString("0.####", CultureInfo.InvariantCulture) : "(none)"; }
    }
    public void ApplyBalancePublic(double bal, bool snap) { ApplyBalance(bal, snap); }
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

    public void SaveCanvas(string path) {
        using (Bitmap copy = new Bitmap(_canvas.Width, _canvas.Height, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(copy)) g.DrawImageUnscaled(_canvas, 0, 0);
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





























