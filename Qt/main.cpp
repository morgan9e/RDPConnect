// RDPConnect: Qt 6 Widgets front-end for sdl-freerdp (Windows and Linux).
// Same settings, favorites.json/last.json and keyring entries (Credential Manager
// on Windows, the GTK build's libsecret schema on Linux), so data carries over.

#ifndef _WIN32
// Before Qt: GLib headers use "signals" as an identifier, which Qt defines as a macro.
#include <libsecret/secret.h>
#endif

#include <QApplication>
#include <QCheckBox>
#include <QCloseEvent>
#include <QComboBox>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QInputDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
#include <QPainter>
#include <QPlainTextEdit>
#include <QProcess>
#include <QRegularExpression>
#include <QPushButton>
#include <QSaveFile>
#include <QScreen>
#include <QScrollArea>
#include <QStandardPaths>
#include <QToolButton>
#include <QUuid>
#include <QVBoxLayout>

#ifdef _WIN32
#include <windows.h>
#include <wincred.h>
#endif

#include <algorithm>
#include <cstdlib>
#include <optional>

namespace {

const QStringList RESOLUTION_PRESETS = {
    "2560x1600", "2560x1440", "1920x1200", "1920x1080",
    "1600x900", "1440x900", "1366x768", "1280x800", "1024x768",
};

const QStringList MODE_IDS    = { "fixed", "dynamic", "scale" };
const QStringList MODE_LABELS = { "Fixed size", "Dynamic resolution", "Scale to fit" };

const QStringList SCALE_PRESETS        = { "100", "125", "150", "175", "200", "Custom" };
const QStringList SCALE_LABELS         = { "100 %", "125 %", "150 %", "175 %", "200 %", "Custom..." };
const QStringList SERVER_SCALE_PRESETS = { "100", "125", "150", "175", "200", "225", "250", "Custom" };
const QStringList SERVER_SCALE_LABELS  = {
    "Off (100 %)", "125 %", "150 %", "175 %", "200 %", "225 %", "250 %", "Custom...",
};

const QString LAST_KEYRING_ID = "last-connection";

// Leading-digits parse, like GLib's int.parse ("150 %" -> 150).
int parseInt(const QString &s) { return std::atoi(s.trimmed().toUtf8().constData()); }

int even(int n) { return std::max(n - (n % 2), 2); }

int gcd(int a, int b) { return b == 0 ? a : gcd(b, a % b); }

struct Connection {
    QString host, username, password, domain;

    QString resolution = "Fullscreen";
    QString customResolution = "1920x1200";
    QString displayMode = "dynamic";
    QString clientScale = "100";
    QString customScale = "150";
    QString serverScale = "100";
    QString customServerScale = "150";
    bool multiMonitor = false;

    bool ignoreCert = true;
    bool clipboard = true;
    bool audio = true;
    bool microphone = false;
    bool driveRedirect = false;

    QString extraArgs;

    static int percent(const QString &value, const QString &custom) {
        int v = parseInt(QString(value == "Custom" ? custom : value).remove('%'));
        if (v <= 0) v = 100;
        return std::clamp(v, 50, 500);
    }

    int scalePercent() const { return percent(clientScale, customScale); }
    int serverScalePercent() const { return percent(serverScale, customServerScale); }

    static bool parseSize(const QString &s, int &w, int &h) {
        w = h = 0;
        QString t = s.toLower().replace(QChar(0x00D7), 'x');
        const QStringList parts = t.split(QRegularExpression("[x ]"), Qt::SkipEmptyParts);
        if (parts.size() != 2) return false;
        w = parseInt(parts[0]);
        h = parseInt(parts[1]);
        return w > 0 && h > 0;
    }

    static QString aspectRatio(int w, int h) {
        int g = std::max(gcd(w, h), 1);
        int rw = w / g, rh = h / g;
        const QString key = QString("%1:%2").arg(rw).arg(rh);
        if (key == "16:9")  return "16:9";
        if (key == "8:5" || key == "16:10") return "16:10";
        if (key == "4:3")   return "4:3";
        if (key == "5:4")   return "5:4";
        if (key == "3:2")   return "3:2";
        if (key == "1:1")   return "1:1";
        if (key == "43:18" || key == "64:27" || key == "12:5" || key == "21:9") return "21:9";
        if (rw <= 24 && rh <= 24) return key;
        double r = double(w) / double(h);
        return r >= 1 ? QString::asprintf("%.2f:1", r) : QString::asprintf("1:%.2f", 1 / r);
    }

    static QString js(const QJsonObject &o, const char *key, const QString &dflt) {
        auto v = o.value(key);
        return v.isString() ? v.toString() : dflt;
    }

    static bool jb(const QJsonObject &o, const char *key, bool dflt) {
        auto v = o.value(key);
        return v.isBool() ? v.toBool() : dflt;
    }

    static QString jScale(const QJsonObject &o, const char *key, const QString &dflt) {
        auto v = o.value(key);
        if (v.isString()) return v.toString();
        if (v.isDouble()) return QString::number(v.toInteger());
        return dflt;
    }

    static Connection fromJson(const QJsonObject &o) {
        Connection c;
        c.host = js(o, "host", c.host);
        QString oldPort = js(o, "port", "");
        if (!oldPort.isEmpty() && oldPort != "3389" && !c.host.contains(':'))
            c.host = c.host + ":" + oldPort;
        c.username = js(o, "username", c.username);
        c.domain = js(o, "domain", c.domain);

        QString savedRes = js(o, "resolution", c.resolution);
        if (savedRes == "Fullscreen" || savedRes == "Custom" || RESOLUTION_PRESETS.contains(savedRes)) {
            c.resolution = savedRes;
            c.customResolution = js(o, "custom_resolution", c.customResolution);
        } else {
            c.resolution = "Custom";
            c.customResolution = savedRes;
        }

        c.displayMode = js(o, "display_mode", c.displayMode);

        c.clientScale = jScale(o, "client_scale", jScale(o, "scale", c.clientScale));
        c.customScale = js(o, "custom_scale", c.customScale);
        c.serverScale = jScale(o, "server_scale", c.serverScale);
        c.customServerScale = js(o, "custom_server_scale", c.customServerScale);

        c.extraArgs = js(o, "extra_args", c.extraArgs);
        c.multiMonitor = jb(o, "multi_monitor", c.multiMonitor);
        c.ignoreCert = jb(o, "ignore_cert", c.ignoreCert);
        c.clipboard = jb(o, "clipboard", c.clipboard);
        c.audio = jb(o, "audio", c.audio);
        c.microphone = jb(o, "microphone", c.microphone);
        c.driveRedirect = jb(o, "drive_redirect", c.driveRedirect);

        if (c.displayMode == "scale-server") {
            c.displayMode = "fixed";
            if (c.serverScale == "100" && c.clientScale != "100")
                c.serverScale = c.clientScale;
            c.clientScale = "100";
        }

        if (!SCALE_PRESETS.contains(c.clientScale)) {
            c.customScale = c.clientScale;
            c.clientScale = "Custom";
        }
        if (!SERVER_SCALE_PRESETS.contains(c.serverScale)) {
            c.customServerScale = c.serverScale;
            c.serverScale = "Custom";
        }

        if (!MODE_IDS.contains(c.displayMode)) c.displayMode = "dynamic";
        return c;
    }

    QJsonObject toJson() const {
        return {
            { "host", host },
            { "username", username },
            { "domain", domain },
            { "resolution", resolution },
            { "custom_resolution", customResolution },
            { "display_mode", displayMode },
            { "client_scale", clientScale },
            { "custom_scale", customScale },
            { "server_scale", serverScale },
            { "custom_server_scale", customServerScale },
            { "extra_args", extraArgs },
            { "multi_monitor", multiMonitor },
            { "ignore_cert", ignoreCert },
            { "clipboard", clipboard },
            { "audio", audio },
            { "microphone", microphone },
            { "drive_redirect", driveRedirect },
        };
    }

    std::optional<QStringList> buildArguments(QString &error, int screenW = 0, int screenH = 0) const {
        error.clear();
        QString h = host.trimmed();
        if (h.isEmpty()) {
            error = "Server address is required.";
            return std::nullopt;
        }

        QStringList args;
        args << "/v:" + h;

        QString user = username.trimmed();
        if (!user.isEmpty()) args << "/u:" + user;
        QString dom = domain.trimmed();
        if (!dom.isEmpty()) args << "/d:" + dom;
        if (!password.isEmpty()) args << "/p:" + password;

        bool fullscreen = (resolution == "Fullscreen");
        int bw = 0, bh = 0;
        bool haveBase = false;
        if (fullscreen) {
            if (screenW > 0 && screenH > 0) { bw = screenW; bh = screenH; haveBase = true; }
        } else {
            QString sizeStr = (resolution == "Custom") ? customResolution : resolution;
            if (!parseSize(sizeStr, bw, bh)) {
                error = QString("Invalid resolution '%1'. Use WIDTHxHEIGHT, e.g. 1920x1200.").arg(sizeStr);
                return std::nullopt;
            }
            haveBase = true;
        }

        auto sizeArgs = [&] {
            if (fullscreen) args << "/f";
            else if (haveBase) args << QString("/w:%1").arg(even(bw)) << QString("/h:%1").arg(even(bh));
        };

        sizeArgs();
        if (displayMode == "scale") {
            if (haveBase) {
                double factor = scalePercent() / 100.0;
                int sw = even(std::max(int(bw / factor + 0.5), 320));
                int sh = even(std::max(int(bh / factor + 0.5), 240));
                args << QString("/smart-sizing:%1x%2").arg(sw).arg(sh);
            } else {
                args << "/smart-sizing";
            }
        } else if (displayMode == "dynamic") {
            args << "/dynamic-resolution";
        }

        int spct = serverScalePercent();
        if (spct != 100) args << QString("/scale-desktop:%1").arg(std::clamp(spct, 100, 500));
        if (multiMonitor) args << "/multimon";

        if (ignoreCert) args << "/cert:ignore";
        if (clipboard) args << "+clipboard";
        if (audio) args << "/sound";
        if (microphone) args << "/microphone";
        if (driveRedirect) args << "/drive:home," + QDir::toNativeSeparators(QDir::homePath());

        args << extraArgs.split(QRegularExpression("\\s+"), Qt::SkipEmptyParts);
        return args;
    }
};

struct Favorite {
    QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QString name;
    Connection conn;
};

namespace Keyring {

#ifdef _WIN32
// Windows Credential Manager, generic credentials named "RDPConnect:<id>" (UTF-8 blob).

std::wstring target(const QString &id) { return ("RDPConnect:" + id).toStdWString(); }

void remove(const QString &id) {
    CredDeleteW(target(id).c_str(), CRED_TYPE_GENERIC, 0);
}

void store(const QString &id, const QString &password) {
    remove(id);
    if (password.isEmpty()) return;
    std::wstring name = target(id);
    QByteArray secret = password.toUtf8();
    CREDENTIALW cred = {};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = name.data();
    cred.CredentialBlobSize = DWORD(secret.size());
    cred.CredentialBlob = reinterpret_cast<LPBYTE>(secret.data());
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (!CredWriteW(&cred, 0))
        qWarning("credential manager: could not store %s", qPrintable(id));
}

QString lookup(const QString &id) {
    PCREDENTIALW cred = nullptr;
    if (!CredReadW(target(id).c_str(), CRED_TYPE_GENERIC, 0, &cred)) return {};
    QString secret = QString::fromUtf8(reinterpret_cast<const char *>(cred->CredentialBlob),
                                       qsizetype(cred->CredentialBlobSize));
    CredFree(cred);
    return secret;
}

#else
// Secret Service via libsecret, same schema as the GTK build.
const SecretSchema *schema() {
    static const SecretSchema s = {
        "com.example.RDPConnect", SECRET_SCHEMA_NONE,
        { { "uuid", SECRET_SCHEMA_ATTRIBUTE_STRING }, { nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING } },
    };
    return &s;
}

void warn(GError *error) {
    if (!error) return;
    qWarning("keyring: %s", error->message);
    g_error_free(error);
}

void remove(const QString &id) {
    GError *error = nullptr;
    secret_password_clear_sync(schema(), nullptr, &error, "uuid", qUtf8Printable(id), nullptr);
    warn(error);
}

void store(const QString &id, const QString &password) {
    remove(id);
    if (password.isEmpty()) return;
    GError *error = nullptr;
    secret_password_store_sync(schema(), SECRET_COLLECTION_DEFAULT, qUtf8Printable("RDPConnect: " + id),
                               qUtf8Printable(password), nullptr, &error, "uuid", qUtf8Printable(id), nullptr);
    warn(error);
}

QString lookup(const QString &id) {
    GError *error = nullptr;
    gchar *secret = secret_password_lookup_sync(schema(), nullptr, &error, "uuid", qUtf8Printable(id), nullptr);
    warn(error);
    QString result = QString::fromUtf8(secret);
    secret_password_free(secret);
    return result;
}
#endif

} // namespace Keyring

QString findBinary() {
#ifdef _WIN32
    const QStringList names = { "sdl-freerdp", "sdl-freerdp3", "wfreerdp" };
#else
    const QStringList names = { "sdl-freerdp", "sdl-freerdp3" };
#endif
    for (const auto &name : names) {
        QString p = QStandardPaths::findExecutable(name, { QCoreApplication::applicationDirPath() });
        if (!p.isEmpty()) return p;
    }
    for (const auto &name : names) {
        QString p = QStandardPaths::findExecutable(name);
        if (!p.isEmpty()) return p;
    }
    return {};
}

// %LOCALAPPDATA%\RDPConnect, the same directory GLib's user data dir gives the GTK build.
QString dataFile(const QString &name) {
    QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/RDPConnect";
    QDir().mkpath(dir);
    return dir + "/" + name;
}

std::optional<QJsonDocument> readJson(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return std::nullopt;
    QJsonParseError err;
    auto doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError) return std::nullopt;
    return doc;
}

bool writeJson(const QString &path, const QJsonDocument &doc, QString *error = nullptr) {
    QSaveFile f(path);
    if (f.open(QIODevice::WriteOnly) && f.write(doc.toJson(QJsonDocument::Indented)) >= 0 && f.commit())
        return true;
    if (error) *error = f.errorString();
    return false;
}

#ifdef _WIN32
// Icon from a Segoe Fluent Icons (Windows 11) / Segoe MDL2 Assets (Windows 10) glyph.
using Glyph = char16_t;

QIcon glyphIcon(Glyph glyph, const QColor &color) {
    QString family = QFontDatabase::hasFamily("Segoe Fluent Icons") ? "Segoe Fluent Icons"
                                                                    : "Segoe MDL2 Assets";
    QIcon icon;
    for (int px : { 16, 20, 24, 32, 40, 48 }) {
        QPixmap pm(px, px);
        pm.fill(Qt::transparent);
        QPainter p(&pm);
        QFont f(family);
        f.setPixelSize(px);
        p.setFont(f);
        p.setPen(color);
        p.drawText(pm.rect(), Qt::AlignCenter, QString(QChar(glyph)));
        icon.addPixmap(pm);
    }
    return icon;
}

constexpr Glyph GLYPH_VIEW = 0xE890;
constexpr Glyph GLYPH_HIDE = 0xED1A;
constexpr Glyph GLYPH_CONSOLE = 0xE756;
constexpr Glyph GLYPH_SAVE = 0xE74E;
constexpr Glyph GLYPH_DELETE = 0xE74D;
#else
// Symbolic icon from the desktop icon theme, recolored like the Windows glyphs.
using Glyph = const char *;

QIcon glyphIcon(Glyph name, const QColor &color) {
    QIcon source = QIcon::fromTheme(name);
    if (source.isNull()) return {};
    QIcon icon;
    for (int px : { 16, 20, 24, 32, 40, 48 }) {
        QPixmap pm = source.pixmap(px, px);
        QPainter p(&pm);
        p.setCompositionMode(QPainter::CompositionMode_SourceIn);
        p.fillRect(pm.rect(), color);
        p.end();
        icon.addPixmap(pm);
    }
    return icon;
}

constexpr Glyph GLYPH_VIEW = "view-reveal-symbolic";
constexpr Glyph GLYPH_HIDE = "view-conceal-symbolic";
constexpr Glyph GLYPH_CONSOLE = "utilities-terminal-symbolic";
constexpr Glyph GLYPH_SAVE = "document-save-symbolic";
constexpr Glyph GLYPH_DELETE = "user-trash-symbolic";
#endif

class LogWindow : public QWidget {
public:
    QPlainTextEdit *view;

    LogWindow() {
        setWindowTitle("RDPConnect Log");
        resize(640, 400);

        view = new QPlainTextEdit;
        view->setReadOnly(true);
        view->setMaximumBlockCount(5000);
        view->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));

        auto *clear = new QPushButton("Clear");
        connect(clear, &QPushButton::clicked, view, &QPlainTextEdit::clear);

        auto *buttons = new QHBoxLayout;
        buttons->addStretch();
        buttons->addWidget(clear);

        auto *layout = new QVBoxLayout(this);
        layout->addWidget(view);
        layout->addLayout(buttons);
    }

    void append(const QString &line) { view->appendPlainText(line); }
};

class MainWindow : public QWidget {
public:
    MainWindow() {
        setWindowTitle("RDPConnect");
        resize(480, 720);

        binary = findBinary();
        buildUi();
        loadFavorites();
        loadLast();
        rebuildFavorites();
        setStatus(!binary.isEmpty() ? "Ready." : "sdl-freerdp not found.");
    }

protected:
    void changeEvent(QEvent *e) override {
        if (e->type() == QEvent::PaletteChange || e->type() == QEvent::ThemeChange)
            updateIcons();
        if (e->type() == QEvent::ThemeChange && btnConnect)
            updateConnectColor();
        QWidget::changeEvent(e);
    }

    void closeEvent(QCloseEvent *e) override {
        if (process) {
            auto answer = QMessageBox::question(
                this, "RDPConnect",
                QString("Closing RDPConnect will end the session to %1.").arg(runningHost),
                QMessageBox::Close | QMessageBox::Cancel, QMessageBox::Cancel);
            if (answer != QMessageBox::Close) {
                e->ignore();
                return;
            }
            process->disconnect(this);
            process->kill();
            process->waitForFinished(3000);
        }
        logWindow.close();
        e->accept();
    }

private:
    QString binary;
    QList<Favorite> favorites;
    QString selectedId;
    QProcess *process = nullptr;
    QString runningHost;
    QByteArray pendingOutput;

    LogWindow logWindow;

    QComboBox *favCombo;
    QPushButton *btnSave;
    QPushButton *btnDelete;

    QLineEdit *editHost;
    QLineEdit *editUser;
    QLineEdit *editPass;
    QAction *revealAction;

    QFormLayout *form;
    QComboBox *comboResolution;
    QStringList resolutionValues;
    QLineEdit *editCustomRes;
    QWidget *customResRow;
    QLabel *aspectLabel;
    QComboBox *comboMode;
    QComboBox *comboScale;
    QLineEdit *editCustomScale;
    QComboBox *comboServerScale;
    QLineEdit *editCustomServerScale;

    QLineEdit *editDomain;
    QCheckBox *chkMultimon;
    QCheckBox *chkCert;
    QCheckBox *chkClipboard;
    QCheckBox *chkAudio;
    QCheckBox *chkMic;
    QCheckBox *chkDrive;
    QLineEdit *editExtra;

    QLabel *statusLabel;
    QToolButton *btnLog = nullptr;
    QPushButton *btnConnect = nullptr;

    static QComboBox *makeCombo(const QStringList &labels) {
        auto *c = new QComboBox;
        c->addItems(labels);
        return c;
    }

    void buildUi() {
        // Favorites bar
        favCombo = new QComboBox;
        favCombo->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
        favCombo->setToolTip("Favorites");
        connect(favCombo, &QComboBox::activated, this, [this](int index) {
            QString id = favCombo->itemData(index).toString();
            if (id.isEmpty()) newConnection();
            else loadFavorite(id);
        });

        btnSave = new QPushButton("Save");
        btnSave->setToolTip("Save as favorite");
        connect(btnSave, &QPushButton::clicked, this, [this] { saveClicked(); });
        btnDelete = new QPushButton("Delete");
        btnDelete->setToolTip("Delete favorite");
        connect(btnDelete, &QPushButton::clicked, this, [this] { deleteClicked(); });

        auto *favBar = new QHBoxLayout;
        favBar->addWidget(favCombo);
        favBar->addWidget(btnSave);
        favBar->addWidget(btnDelete);

        // Connection
        editHost = new QLineEdit;
        editHost->setPlaceholderText("host or host:port");
        editUser = new QLineEdit;
        editPass = new QLineEdit;
        editPass->setEchoMode(QLineEdit::Password);
        revealAction = editPass->addAction(QIcon(), QLineEdit::TrailingPosition);
        revealAction->setToolTip("Show password");
        connect(revealAction, &QAction::triggered, this, [this] {
            bool show = editPass->echoMode() == QLineEdit::Password;
            editPass->setEchoMode(show ? QLineEdit::Normal : QLineEdit::Password);
            revealAction->setToolTip(show ? "Hide password" : "Show password");
            updateIcons();
        });
        for (auto *e : { editHost, editUser, editPass })
            connect(e, &QLineEdit::returnPressed, this, [this] { if (!process) connectClicked(); });

        auto *page = new QWidget;
        form = new QFormLayout(page);
        form->setVerticalSpacing(8);
        addSection("Connection", true);
        form->addRow("Server:", editHost);
        form->addRow("Username:", editUser);
        form->addRow("Password:", editPass);

        // Display
        QStringList resLabels = { "Fullscreen" };
        resolutionValues = { "Fullscreen" };
        resLabels << RESOLUTION_PRESETS;
        resolutionValues << RESOLUTION_PRESETS;
        resLabels << "Custom...";
        resolutionValues << "Custom";
        comboResolution = makeCombo(resLabels);

        editCustomRes = new QLineEdit("1920x1200");
        editCustomRes->setPlaceholderText("WIDTHxHEIGHT");
        aspectLabel = new QLabel;
        aspectLabel->setForegroundRole(QPalette::PlaceholderText);
        customResRow = new QWidget;
        auto *customResLayout = new QHBoxLayout(customResRow);
        customResLayout->setContentsMargins(0, 0, 0, 0);
        customResLayout->addWidget(editCustomRes, 1);
        customResLayout->addWidget(aspectLabel);

        comboMode = makeCombo(MODE_LABELS);
        comboMode->setCurrentIndex(1);
        comboScale = makeCombo(SCALE_LABELS);
        editCustomScale = new QLineEdit("150");
        comboServerScale = makeCombo(SERVER_SCALE_LABELS);
        editCustomServerScale = new QLineEdit("150");

        for (auto *c : { comboResolution, comboMode, comboScale, comboServerScale })
            connect(c, &QComboBox::currentIndexChanged, this, [this] { updateDisplayRows(); });
        connect(editCustomRes, &QLineEdit::textChanged, this, [this] { updateAspect(); });

        addSection("Display");
        form->addRow("Resolution:", comboResolution);
        form->addRow("Custom size:", customResRow);
        form->addRow("Mode:", comboMode);
        form->addRow("Client scale:", comboScale);
        form->addRow("Client scale %:", editCustomScale);
        form->addRow("Server scale:", comboServerScale);
        form->addRow("Server scale %:", editCustomServerScale);

        // Options
        editDomain = new QLineEdit;
        chkMultimon = new QCheckBox("Use all monitors");
        chkCert = new QCheckBox("Ignore certificate");
        chkCert->setChecked(true);
        chkClipboard = new QCheckBox("Share clipboard");
        chkClipboard->setChecked(true);
        chkAudio = new QCheckBox("Forward audio");
        chkAudio->setChecked(true);
        chkMic = new QCheckBox("Forward microphone");
        chkDrive = new QCheckBox("Share home folder");
        editExtra = new QLineEdit;
        editExtra->setPlaceholderText("e.g. /gfx /rfx");

        addSection("Options");
        form->addRow("Domain:", editDomain);
        for (auto *c : { chkMultimon, chkCert, chkClipboard, chkAudio, chkMic, chkDrive })
            form->addRow(QString(), c);
        form->addRow("Extra arguments:", editExtra);

        auto *scroll = new QScrollArea;
        scroll->setWidget(page);
        scroll->setWidgetResizable(true);
        scroll->setFrameShape(QFrame::NoFrame);
        scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);

        // Bottom bar
        statusLabel = new QLabel;
        statusLabel->setForegroundRole(QPalette::PlaceholderText);
        statusLabel->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);

        btnLog = new QToolButton;
        btnLog->setToolTip("Show log");
        btnLog->setAutoRaise(true);
        connect(btnLog, &QToolButton::clicked, this, [this] { showLog(); });

        btnConnect = new QPushButton("Connect");
        btnConnect->setDefault(true);
        btnConnect->setMinimumWidth(110);
        connect(btnConnect, &QPushButton::clicked, this, [this] { connectClicked(); });

        auto *bottom = new QHBoxLayout;
        bottom->addWidget(statusLabel, 1);
        bottom->addWidget(btnLog);
        bottom->addWidget(btnConnect);

        auto *root = new QVBoxLayout(this);
        root->addLayout(favBar);
        root->addWidget(scroll, 1);
        root->addLayout(bottom);

        updateIcons();
        updateConnectColor();
        updateDisplayRows();
    }

    // Settings-style section heading spanning both form columns.
    void addSection(const QString &title, bool first = false) {
        auto *label = new QLabel(title);
        QFont f = label->font();
        f.setPointSizeF(f.pointSizeF() * 1.15);
        f.setWeight(QFont::DemiBold);
        label->setFont(f);
        label->setContentsMargins(0, first ? 0 : 16, 0, 4);
        form->addRow(label);
    }

    void updateIcons() {
        if (!btnLog) return;
        QColor fg = palette().color(QPalette::WindowText);
        bool hidden = editPass->echoMode() == QLineEdit::Password;
        revealAction->setIcon(glyphIcon(hidden ? GLYPH_VIEW : GLYPH_HIDE, fg));
        btnLog->setIcon(glyphIcon(GLYPH_CONSOLE, fg));
        btnSave->setIcon(glyphIcon(GLYPH_SAVE, fg));
        btnDelete->setIcon(glyphIcon(GLYPH_DELETE, btnDelete->isEnabled()
                                                       ? fg
                                                       : palette().color(QPalette::Disabled, QPalette::WindowText)));
    }

    void updateDisplayRows() {
        form->setRowVisible(customResRow, resolutionValues[comboResolution->currentIndex()] == "Custom");

        bool scale = MODE_IDS[comboMode->currentIndex()] == "scale";
        form->setRowVisible(comboScale, scale);
        form->setRowVisible(editCustomScale, scale && SCALE_PRESETS[comboScale->currentIndex()] == "Custom");
        form->setRowVisible(editCustomServerScale,
                                SERVER_SCALE_PRESETS[comboServerScale->currentIndex()] == "Custom");
        updateAspect();
    }

    void updateAspect() {
        int w, h;
        bool show = resolutionValues[comboResolution->currentIndex()] == "Custom"
                    && Connection::parseSize(editCustomRes->text(), w, h);
        aspectLabel->setText(show ? Connection::aspectRatio(w, h) : QString());
    }

    Connection formToConn() const {
        Connection c;
        c.host = editHost->text();
        c.username = editUser->text();
        c.password = editPass->text();
        c.domain = editDomain->text();
        c.resolution = resolutionValues[comboResolution->currentIndex()];
        c.customResolution = editCustomRes->text();
        c.displayMode = MODE_IDS[comboMode->currentIndex()];
        c.clientScale = SCALE_PRESETS[comboScale->currentIndex()];
        c.customScale = editCustomScale->text();
        c.serverScale = SERVER_SCALE_PRESETS[comboServerScale->currentIndex()];
        c.customServerScale = editCustomServerScale->text();
        c.multiMonitor = chkMultimon->isChecked();
        c.ignoreCert = chkCert->isChecked();
        c.clipboard = chkClipboard->isChecked();
        c.audio = chkAudio->isChecked();
        c.microphone = chkMic->isChecked();
        c.driveRedirect = chkDrive->isChecked();
        c.extraArgs = editExtra->text();
        return c;
    }

    static int indexOf(const QStringList &list, const QString &value, int dflt) {
        int i = list.indexOf(value);
        return i >= 0 ? i : dflt;
    }

    void connToForm(const Connection &c) {
        editHost->setText(c.host);
        editUser->setText(c.username);
        editPass->setText(c.password);
        editDomain->setText(c.domain);
        comboResolution->setCurrentIndex(indexOf(resolutionValues, c.resolution, 0));
        editCustomRes->setText(c.customResolution);
        comboMode->setCurrentIndex(indexOf(MODE_IDS, c.displayMode, 1));
        comboScale->setCurrentIndex(indexOf(SCALE_PRESETS, c.clientScale, 0));
        editCustomScale->setText(c.customScale);
        comboServerScale->setCurrentIndex(indexOf(SERVER_SCALE_PRESETS, c.serverScale, 0));
        editCustomServerScale->setText(c.customServerScale);
        chkMultimon->setChecked(c.multiMonitor);
        chkCert->setChecked(c.ignoreCert);
        chkClipboard->setChecked(c.clipboard);
        chkAudio->setChecked(c.audio);
        chkMic->setChecked(c.microphone);
        chkDrive->setChecked(c.driveRedirect);
        editExtra->setText(c.extraArgs);
        updateDisplayRows();
    }

    Favorite *findFavorite(const QString &id) {
        if (id.isEmpty()) return nullptr;
        for (auto &f : favorites)
            if (f.id == id) return &f;
        return nullptr;
    }

    void loadFavorites() {
        auto doc = readJson(dataFile("favorites.json"));
        if (!doc || !doc->isArray()) return;
        for (const auto &v : doc->array()) {
            if (!v.isObject()) continue;
            QJsonObject o = v.toObject();
            Favorite fav;
            fav.name = o.value("name").toString();
            if (fav.name.isEmpty()) continue;
            QString id = o.value("id").toString();
            if (!id.isEmpty()) fav.id = id;
            if (o.value("conn").isObject())
                fav.conn = Connection::fromJson(o.value("conn").toObject());
            favorites << fav;
        }
    }

    void persistFavorites() {
        QJsonArray arr;
        for (const auto &f : favorites)
            arr.append(QJsonObject{ { "id", f.id }, { "name", f.name }, { "conn", f.conn.toJson() } });
        QString err;
        if (!writeJson(dataFile("favorites.json"), QJsonDocument(arr), &err))
            setStatus("Could not save favorites: " + err);
    }

    void sortFavorites() {
        std::stable_sort(favorites.begin(), favorites.end(), [](const Favorite &a, const Favorite &b) {
            return QString::localeAwareCompare(a.name.toCaseFolded(), b.name.toCaseFolded()) < 0;
        });
    }

    void rebuildFavorites() {
        Favorite *selected = findFavorite(selectedId);

        QSignalBlocker block(favCombo);
        favCombo->clear();
        favCombo->addItem("New connection", QString());
        if (!favorites.isEmpty()) favCombo->insertSeparator(1);
        for (const auto &f : favorites)
            favCombo->addItem(f.name, f.id);
        int idx = selected ? favCombo->findData(selected->id) : 0;
        favCombo->setCurrentIndex(std::max(idx, 0));

        btnDelete->setEnabled(selected != nullptr);
        updateIcons();
        setWindowTitle(selected ? selected->name + " - RDPConnect" : "RDPConnect");
    }

    void loadFavorite(const QString &id) {
        Favorite *fav = findFavorite(id);
        if (!fav) return;
        Connection c = fav->conn;
        c.password = Keyring::lookup(fav->id);
        selectedId = fav->id;
        connToForm(c);
        rebuildFavorites();
        setStatus(QString("Loaded '%1'.").arg(fav->name));
    }

    void newConnection() {
        selectedId.clear();
        connToForm(Connection());
        rebuildFavorites();
        setStatus("New connection.");
        editHost->setFocus();
    }

    void saveClicked() {
        Favorite *selected = findFavorite(selectedId);
        QString dflt = selected ? selected->name : editHost->text().trimmed();
        bool ok = false;
        QString name = QInputDialog::getText(this, "Save Favorite", "Name:", QLineEdit::Normal, dflt, &ok);
        if (ok) saveFavorite(name.trimmed());
    }

    void saveFavorite(const QString &name) {
        if (name.isEmpty()) return;
        Connection conn = formToConn();
        QString password = conn.password;
        conn.password.clear();

        Favorite *fav = nullptr;
        for (auto &f : favorites)
            if (f.name == name) { fav = &f; break; }
        if (fav) {
            fav->conn = conn;
        } else {
            Favorite f;
            f.name = name;
            f.conn = conn;
            favorites << f;
            fav = &favorites.last();
        }
        Keyring::store(fav->id, password);
        selectedId = fav->id;
        sortFavorites();
        persistFavorites();
        rebuildFavorites();
        setStatus(QString("Saved '%1'.").arg(name));
    }

    void deleteClicked() {
        Favorite *fav = findFavorite(selectedId);
        if (!fav) return;
        auto answer = QMessageBox::question(this, "Delete Favorite",
                                            QString("Delete '%1'?").arg(fav->name),
                                            QMessageBox::Yes | QMessageBox::No, QMessageBox::No);
        if (answer != QMessageBox::Yes) return;
        QString name = fav->name;
        Keyring::remove(fav->id);
        favorites.removeIf([&](const Favorite &f) { return f.id == selectedId; });
        selectedId.clear();
        persistFavorites();
        rebuildFavorites();
        setStatus(QString("Deleted '%1'.").arg(name));
    }

    void saveLast(const Connection &conn) {
        QJsonObject o{ { "selected_id", selectedId }, { "conn", conn.toJson() } };
        if (!writeJson(dataFile("last.json"), QJsonDocument(o)))
            qWarning("last connection: could not write");
        Keyring::store(LAST_KEYRING_ID, conn.password);
    }

    void loadLast() {
        auto doc = readJson(dataFile("last.json"));
        if (!doc || !doc->isObject()) return;
        QJsonObject o = doc->object();
        if (!o.value("conn").isObject()) return;
        Connection c = Connection::fromJson(o.value("conn").toObject());
        c.password = Keyring::lookup(LAST_KEYRING_ID);
        QString id = o.value("selected_id").toString();
        selectedId = findFavorite(id) ? id : QString();
        connToForm(c);
    }

    void setStatus(const QString &text) {
        statusLabel->setText(text);
        statusLabel->setToolTip(text);
    }

    void appendLog(const QString &line) { logWindow.append(line); }

    void showLog() {
        logWindow.show();
        logWindow.raise();
        logWindow.activateWindow();
    }

    void connectClicked() {
        if (process) {
            process->kill();
            return;
        }
        if (binary.isEmpty()) {
            setStatus("sdl-freerdp not found.");
#ifdef _WIN32
            appendLog("sdl-freerdp not found. Put sdl-freerdp.exe next to rdpconnect.exe, "
                      "or install it with MSYS2 (pacman -S mingw-w64-ucrt-x86_64-freerdp).");
#else
            appendLog("sdl-freerdp not found. Install it with your "
                      "package manager (e.g. dnf install freerdp).");
#endif
            return;
        }
        Connection conn = formToConn();
        int monW = 0, monH = 0;
        if (QScreen *s = screen()) {
            QRect geo = s->geometry();
            monW = qRound(geo.width() * s->devicePixelRatio());
            monH = qRound(geo.height() * s->devicePixelRatio());
        }
        QString err;
        auto args = conn.buildArguments(err, monW, monH);
        if (!args) {
            setStatus(err.isEmpty() ? "Invalid settings." : err);
            return;
        }
        launch(conn, *args);
    }

    void launch(const Connection &conn, const QStringList &args) {
        QStringList shown = { QDir::toNativeSeparators(binary) };
        for (const auto &a : args)
            shown << (a.startsWith("/p:") ? "/p:******" : a);
        appendLog("run: " + shown.join(' '));

        auto *proc = new QProcess(this);
        proc->setProcessChannelMode(QProcess::MergedChannels);
        proc->setProgram(binary);
        proc->setArguments(args);
        proc->setWorkingDirectory(QFileInfo(binary).absolutePath());

        connect(proc, &QProcess::readyReadStandardOutput, this, [this, proc] {
            pendingOutput += proc->readAllStandardOutput();
            qsizetype nl;
            while ((nl = pendingOutput.indexOf('\n')) >= 0) {
                appendLog(QString::fromUtf8(pendingOutput.left(nl)).trimmed());
                pendingOutput.remove(0, nl + 1);
            }
        });
        connect(proc, &QProcess::errorOccurred, this, [this, proc](QProcess::ProcessError e) {
            if (e != QProcess::FailedToStart) return;
            setStatus("Failed to launch.");
            appendLog("Failed to launch: " + proc->errorString());
            process = nullptr;
            setConnectState(false);
            proc->deleteLater();
        });
        connect(proc, &QProcess::finished, this, [this, proc](int exitCode, QProcess::ExitStatus status) {
            if (!pendingOutput.isEmpty())
                appendLog(QString::fromUtf8(pendingOutput).trimmed());
            pendingOutput.clear();
            int code = status == QProcess::NormalExit ? exitCode : -1;
            process = nullptr;
            setConnectState(false);
            setStatus(QString("Session ended (exit %1).").arg(code));
            appendLog(QString("Session ended (exit code %1)").arg(code));
            proc->deleteLater();
        });

        process = proc;
        runningHost = conn.host.trimmed();
        pendingOutput.clear();
        proc->start();
        if (!process) return;  // errorOccurred(FailedToStart) already handled it

        saveLast(conn);
        setConnectState(true);
        setStatus(QString("Connected to %1.").arg(runningHost));
    }

    void setConnectState(bool running) {
        btnConnect->setText(running ? "Disconnect" : "Connect");
        updateConnectColor();
    }

    // Accent-filled primary button while idle, a plain button while a session runs.
    void updateConnectColor() {
        QPalette pal = palette();
        if (!process) {
            for (auto group : { QPalette::Active, QPalette::Inactive }) {
                QColor accent = pal.color(group, QPalette::Accent);
                pal.setColor(group, QPalette::Button, accent);
                pal.setColor(group, QPalette::ButtonText, accent.lightnessF() > 0.6 ? Qt::black : Qt::white);
            }
        }
        btnConnect->setPalette(pal);
    }
};

} // namespace

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    QApplication::setApplicationName("RDPConnect");
    QApplication::setOrganizationName("RDPConnect");
#ifndef _WIN32
    QGuiApplication::setDesktopFileName("com.example.RDPConnect");
    QApplication::setWindowIcon(QIcon::fromTheme("rdpconnect"));
#endif

    MainWindow win;
    win.show();
    return app.exec();
}
