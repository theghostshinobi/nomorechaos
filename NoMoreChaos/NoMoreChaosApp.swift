import SwiftUI

@main
struct NoMoreChaosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        MenuBarExtra("NoMoreChaos", image: "MenuBarIcon") {
            MenuContent()
        }

        Window("NoMoreChaos", id: "main-panel") {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(WindowTracker.shared)
        }
        .defaultSize(width: 900, height: 600)
    }
}

// MARK: - Menu Bar Menu
//
// In its own View so it can use the SwiftUI openWindow action (reliable
// cold-start window opening) and observe the Localizer for live language
// switching.
private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var loc = Localizer.shared
    @AppStorage("onboardingComplete") private var onboardingDone = false

    var body: some View {
        Button(loc.tr("menu.toggleHUD") + "  ⌘§") {
            AppDelegate.toggleHUD()
        }
        .disabled(!onboardingDone)

        Button(loc.tr("menu.map")) {
            AppDelegate.switchToMap()
        }
        .disabled(!onboardingDone)

        Divider()

        Button(loc.tr("menu.showManager")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main-panel")
        }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(!onboardingDone)

        Button(loc.tr("menu.setup")) {
            AppDelegate.showWizard()
        }

        Divider()

        // Language switch — English default, Italian optional.
        Picker(loc.tr("menu.language"), selection: Binding(
            get: { loc.lang },
            set: { Localizer.shared.setLanguage($0) }
        )) {
            Text("English").tag("en")
            Text("Italiano").tag("it")
        }

        Divider()

        Button(loc.tr("menu.quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}

// ============================================================================
// MARK: - Localizer
//
// Runtime EN/IT localization. English is the default; the choice persists in
// UserDefaults and switches instantly (no restart) because every user-facing
// view observes this shared ObservableObject. Lives here (not a new file)
// because the project has no file-system-synchronized groups.
// ============================================================================

final class Localizer: ObservableObject {
    static let shared = Localizer()

    @Published private(set) var lang: String

    private init() {
        lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
    }

    func setLanguage(_ code: String) {
        guard code != lang, Self.table[code] != nil else { return }
        lang = code   // @Published → all observing views repaint instantly
        UserDefaults.standard.set(code, forKey: "appLanguage")
    }

    /// Lookup order: active language → English → raw key.
    func tr(_ key: String) -> String {
        Self.table[lang]?[key] ?? Self.table["en"]?[key] ?? key
    }

    /// For "%d"-style strings (counts, idle minutes).
    func tr(_ key: String, _ n: Int) -> String {
        String(format: tr(key), n)
    }

    static let table: [String: [String: String]] = [
        "en": [
            "menu.toggleHUD": "Toggle HUD",
            "menu.map": "Visual Map",
            "menu.showManager": "Show Project Manager",
            "menu.language": "Language",
            "menu.quit": "Quit NoMoreChaos",
            "menu.setup": "Setup Assistant",

            "wizard.welcome.title": "Welcome to NoMoreChaos",
            "wizard.welcome.body": "Group your open windows into projects and recall them instantly with ⌘§. Let's set up a couple of permissions first.",
            "wizard.start": "Get Started",
            "wizard.back": "Back",
            "wizard.next": "Next",
            "wizard.skip": "Skip",
            "wizard.finish": "Finish",
            "wizard.screen.title": "Screen Recording",
            "wizard.screen.body": "Required so NoMoreChaos can read window titles and capture live previews of your windows. macOS will ask for confirmation.",
            "wizard.screen.grant": "Grant Permission",
            "wizard.screen.openSettings": "Open System Settings",
            "wizard.screen.granted": "Permission granted",
            "wizard.screen.note": "macOS requires the app to restart after granting Screen Recording. Click 'Quit & Reopen' when prompted — the wizard will resume from where you left off.",
            "wizard.screen.relaunch": "I already toggled the switch (Relaunch)",
            "wizard.access.title": "Accessibility",
            "wizard.access.body": "Lets NoMoreChaos see every window of each app — not just the front one — and jump straight to the right window of a project. This is the standard permission used by window managers like Rectangle.",
            "wizard.access.grant": "Grant Permission",
            "wizard.access.openSettings": "Open System Settings",
            "wizard.access.granted": "Permission granted",
            "wizard.access.note": "Switch NoMoreChaos ON under Accessibility, then come back here.",
            "wizard.login.title": "Launch at Login",
            "wizard.login.body": "Keep NoMoreChaos running in the background so the ⌘§ shortcut always works.",
            "wizard.login.toggle": "Start automatically at login",
            "wizard.ai.title": "AI Suggestions",
            "wizard.ai.optional": "optional",
            "wizard.ai.body": "Paste a Google Gemini API key to auto-suggest a project for each new window. You can skip this and add it later in the Project Manager.",
            "wizard.done.title": "You're all set!",
            "wizard.done.body": "Press ⌘§ anywhere to open NoMoreChaos and start grouping your windows.",
            "wizard.troubleshoot.tip": "Tip: If permissions won't register, toggle the switch OFF and ON in Settings. For developers, remove the app with '-' from the list and re-add it.",

            "onboarding.welcome": "Welcome to NoMoreChaos",
            "onboarding.subtitle": "Create your first project. Then you'll assign open windows to this project.",
            "onboarding.placeholder": "Project name…",
            "onboarding.hint": "open / close this panel from any app",
            "common.create": "Create",
            "common.newProject": "New project…",
            "common.addAll": "Add All",

            "hud.map.button": "Map",
            "column.projects": "PROJECTS",
            "hud.addOpenWindows": "ADD OPEN WINDOWS",
            "hud.assignedWindows": "ASSIGNED WINDOWS",
            "empty.noProjects": "No projects",
            "empty.noWindowsAssigned": "No windows assigned",
            "empty.selectWindow": "Select a window",
            "label.untitled": "Untitled",
            "label.unknownApp": "Unknown",

            "shortcut.open": "open",
            "shortcut.project": "project",
            "shortcut.window": "window",
            "shortcut.jump": "jump",
            "shortcut.map": "map",
            "shortcut.focus": "focus",
            "shortcut.remove": "remove",

            "banner.grant": "Grant",
            "banner.screenMissing": "Screen Recording is OFF — titles and previews won't show.",
            "banner.accessMissing": "Accessibility is OFF — NoMoreChaos can't switch to the right window.",
            "banner.bothMissing": "Screen Recording and Accessibility are OFF — grant them to use NoMoreChaos.",

            "status.active": "active",
            "status.unknown": "unknown",
            "status.idle.seconds": "idle %ds ago",
            "status.idle.oneMinute": "idle 1 min ago",
            "status.idle.minutes": "idle %d min ago",

            "map.header": "NoMoreChaos — Visual Map",
            "map.close": "close",
            "map.back": "Back",
            "map.empty": "No projects created",
            "window.count.one": "1 window",
            "window.count.other": "%d windows",

            "suggestion.prefix": "Gemini suggests:",
            "suggestion.for": "for",
            "suggestion.assign": "Assign",
            "suggestion.ignore": "Ignore",

            "windows.header": "Detected Windows",
            "windows.empty.title": "No windows detected.",
            "windows.empty.permission": "Grant the Screen Recording permission in\nSystem Settings → Privacy & Security.",
            "windows.openSettings": "Open System Settings",
            "projects.header": "Projects",
            "projects.newPlaceholder": "New project name…",
            "projects.empty.title": "No projects yet.",
            "projects.empty.subtitle": "Create one above to start grouping windows.",
            "project.noWindowsAssigned": "No windows assigned",
            "picker.none": "— none —",
            "gemini.keyLabel": "Gemini API Key",
            "gemini.notSet": "not set",
            "gemini.active": "active",
            "gemini.placeholder": "Paste your Gemini key…",
        ],
        "it": [
            "menu.toggleHUD": "Mostra/Nascondi HUD",
            "menu.map": "Mappa Visiva",
            "menu.showManager": "Mostra Gestione Progetti",
            "menu.language": "Lingua",
            "menu.quit": "Esci da NoMoreChaos",
            "menu.setup": "Assistente di configurazione",

            "wizard.welcome.title": "Benvenuto in NoMoreChaos",
            "wizard.welcome.body": "Raggruppa le finestre aperte in progetti e richiamale al volo con ⌘§. Prima configuriamo un paio di permessi.",
            "wizard.start": "Inizia",
            "wizard.back": "Indietro",
            "wizard.next": "Avanti",
            "wizard.skip": "Salta",
            "wizard.finish": "Fine",
            "wizard.screen.title": "Registrazione schermo",
            "wizard.screen.body": "Serve a NoMoreChaos per leggere i titoli delle finestre e catturarne le anteprime dal vivo. macOS chiederà conferma.",
            "wizard.screen.grant": "Concedi permesso",
            "wizard.screen.openSettings": "Apri Impostazioni di Sistema",
            "wizard.screen.granted": "Permesso concesso",
            "wizard.screen.note": "macOS richiede il riavvio dell'app dopo aver concesso la Registrazione schermo. Clicca 'Esci e riapri' quando richiesto — il wizard ripartirà da dove eri rimasto.",
            "wizard.screen.relaunch": "Ho già attivato l'interruttore (Riavvia)",
            "wizard.access.title": "Accessibilità",
            "wizard.access.body": "Permette a NoMoreChaos di vedere tutte le finestre di ogni app — non solo quella davanti — e di saltare direttamente alla finestra giusta di un progetto. È il permesso standard dei window-manager come Rectangle.",
            "wizard.access.grant": "Concedi permesso",
            "wizard.access.openSettings": "Apri Impostazioni di Sistema",
            "wizard.access.granted": "Permesso concesso",
            "wizard.access.note": "Attiva NoMoreChaos in Accessibilità, poi torna qui.",
            "wizard.login.title": "Avvio al login",
            "wizard.login.body": "Tieni NoMoreChaos attivo in background così la scorciatoia ⌘§ funziona sempre.",
            "wizard.login.toggle": "Avvia automaticamente al login",
            "wizard.ai.title": "Suggerimenti AI",
            "wizard.ai.optional": "facoltativo",
            "wizard.ai.body": "Incolla una chiave API Google Gemini per suggerire automaticamente un progetto a ogni nuova finestra. Puoi saltare e aggiungerla dopo dalla Gestione Progetti.",
            "wizard.done.title": "Tutto pronto!",
            "wizard.done.body": "Premi ⌘§ ovunque per aprire NoMoreChaos e iniziare a raggruppare le finestre.",
            "wizard.troubleshoot.tip": "Nota: Se i permessi non vengono rilevati, spegni e riaccendi l'opzione in Impostazioni. Per gli sviluppatori: rimuovi l'app con '-' e riaggiungila.",

            "onboarding.welcome": "Benvenuto in NoMoreChaos",
            "onboarding.subtitle": "Crea il tuo primo progetto. Poi assegnerai le finestre aperte a questo progetto.",
            "onboarding.placeholder": "Nome del progetto…",
            "onboarding.hint": "apri / chiudi questo pannello da qualsiasi app",
            "common.create": "Crea",
            "common.newProject": "Nuovo progetto…",
            "common.addAll": "Aggiungi tutte",

            "hud.map.button": "Mappa",
            "column.projects": "PROGETTI",
            "hud.addOpenWindows": "AGGIUNGI FINESTRE APERTE",
            "hud.assignedWindows": "FINESTRE ASSEGNATE",
            "empty.noProjects": "Nessun progetto",
            "empty.noWindowsAssigned": "Nessuna finestra assegnata",
            "empty.selectWindow": "Seleziona una finestra",
            "label.untitled": "Senza titolo",
            "label.unknownApp": "Sconosciuta",

            "shortcut.open": "apri",
            "shortcut.project": "progetto",
            "shortcut.window": "finestra",
            "shortcut.jump": "salta",
            "shortcut.map": "mappa",
            "shortcut.focus": "colonna",
            "shortcut.remove": "rimuovi",

            "banner.grant": "Concedi",
            "banner.screenMissing": "Registrazione schermo SPENTA — niente titoli né anteprime.",
            "banner.accessMissing": "Accessibilità SPENTA — non posso saltare alla finestra giusta.",
            "banner.bothMissing": "Registrazione schermo e Accessibilità sono SPENTE — concedi i permessi per usare NoMoreChaos.",

            "status.active": "attivo",
            "status.unknown": "sconosciuto",
            "status.idle.seconds": "inattivo %ds fa",
            "status.idle.oneMinute": "inattivo 1 min fa",
            "status.idle.minutes": "inattivo %d min fa",

            "map.header": "NoMoreChaos — Mappa Visiva",
            "map.close": "chiudi",
            "map.back": "Indietro",
            "map.empty": "Nessun progetto creato",
            "window.count.one": "1 finestra",
            "window.count.other": "%d finestre",

            "suggestion.prefix": "Gemini suggerisce:",
            "suggestion.for": "per",
            "suggestion.assign": "Assegna",
            "suggestion.ignore": "Ignora",

            "windows.header": "Finestre rilevate",
            "windows.empty.title": "Nessuna finestra rilevata.",
            "windows.empty.permission": "Concedi il permesso di Registrazione schermo in\nImpostazioni di Sistema → Privacy e sicurezza.",
            "windows.openSettings": "Apri Impostazioni di Sistema",
            "projects.header": "Progetti",
            "projects.newPlaceholder": "Nome del nuovo progetto…",
            "projects.empty.title": "Ancora nessun progetto.",
            "projects.empty.subtitle": "Creane uno sopra per iniziare a raggruppare le finestre.",
            "project.noWindowsAssigned": "Nessuna finestra assegnata",
            "picker.none": "— nessuno —",
            "gemini.keyLabel": "Chiave API Gemini",
            "gemini.notSet": "non impostata",
            "gemini.active": "attiva",
            "gemini.placeholder": "Incolla la tua chiave Gemini…",
        ],
    ]
}
