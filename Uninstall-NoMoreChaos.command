#!/bin/zsh
# ============================================================================
#  NoMoreChaos — Uninstaller completo
#  Doppio click su questo file per disinstallare TUTTO:
#   1. chiude l'app se in esecuzione
#   2. elimina il binario da /Applications, dal Desktop e dalla root del repo
#   3. rimuove la voce "Avvio al login" (Background Task Management)
#   4. azzera i permessi macOS (Registrazione schermo, Accessibilità)
#   5. elimina il database Core Data (progetti, finestre, gruppi salvati)
#   6. elimina le preferenze (UserDefaults, chiave Gemini)
#   7. elimina log e cache eventuali
# ============================================================================

set -u

BUNDLE_ID="com.nomorechaos.app"
APP_NAME="NoMoreChaos"

# --- estetica terminale --------------------------------------------------
BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
ok()    { echo "  ${GREEN}✓${RESET} $1"; }
warn()  { echo "  ${YELLOW}!${RESET} $1"; }
skip()  { echo "  ${DIM}·${RESET} $1"; }
step()  { echo; echo "${BOLD}${BLUE}▸${RESET} ${BOLD}$1${RESET}"; }

clear
echo "${BOLD}=========================================${RESET}"
echo "${BOLD}  NoMoreChaos — Uninstaller${RESET}"
echo "${BOLD}=========================================${RESET}"
echo
echo "Sto per rimuovere ${BOLD}TUTTO${RESET} ciò che riguarda NoMoreChaos su questo Mac:"
echo "  • l'applicazione (in /Applications, sul Desktop, nella cartella del progetto)"
echo "  • il database progetti/finestre"
echo "  • le preferenze (incluse le chiavi API salvate)"
echo "  • la voce di avvio-al-login"
echo "  • i permessi macOS concessi (Registrazione schermo, Accessibilità)"
echo
echo "${YELLOW}I sorgenti del progetto e questo script restano intatti.${RESET}"
echo
read "REPLY?Procedere? (s/N) "
if [[ "${REPLY:l}" != "s" && "${REPLY:l}" != "si" && "${REPLY:l}" != "y" && "${REPLY:l}" != "yes" ]]; then
    echo
    echo "${YELLOW}Annullato.${RESET}"
    echo
    read "REPLY?Premi Invio per chiudere."
    exit 0
fi

# ============================================================================
step "1/7  Chiusura dell'app"
# ============================================================================
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null
    sleep 1
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        pkill -x "$APP_NAME" 2>/dev/null
        sleep 1
    fi
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        warn "alcune istanze non si chiudono — provo con KILL"
        pkill -9 -x "$APP_NAME" 2>/dev/null
    fi
    ok "applicazione chiusa"
else
    skip "nessuna istanza attiva"
fi

# ============================================================================
step "2/7  Rimozione dei binari (.app)"
# ============================================================================
APP_PATHS=(
    "/Applications/${APP_NAME}.app"
    "$HOME/Desktop/${APP_NAME}.app"
    "$HOME/Applications/${APP_NAME}.app"
    "$HOME/Desktop/nomorechaos/${APP_NAME}.app"
)
for p in "${APP_PATHS[@]}"; do
    if [[ -e "$p" ]]; then
        rm -rf "$p" && ok "rimosso: $p" || warn "impossibile rimuovere: $p"
    else
        skip "non presente: $p"
    fi
done

# ============================================================================
step "3/7  Voce \"Avvio al login\""
# ============================================================================
# SMAppService scrive nel Background Task Management Database (BTM).
# Tenta la rimozione tramite System Events; se l'app è già sparita, lascia
# la voce come "missing" — la prossima apertura del pannello Login Items in
# Impostazioni di Sistema la mostrerà come "non più disponibile" e si ripulirà.
osascript -e "tell application \"System Events\" to delete login item \"$APP_NAME\"" \
    >/dev/null 2>&1 \
    && ok "voce avvio-al-login rimossa" \
    || skip "nessuna voce di avvio-al-login da rimuovere"

# ============================================================================
step "4/7  Permessi macOS (TCC)"
# ============================================================================
# tccutil reset ripristina lo stato "non ancora deciso" per quel servizio
# limitato a quel bundle ID. Non richiede password.
RESET_OK=0
for service in ScreenCapture Accessibility AppleEvents Microphone Camera; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        ok "permesso azzerato: $service"
        RESET_OK=1
    fi
done
[[ $RESET_OK -eq 0 ]] && skip "nessun permesso TCC associato"

# ============================================================================
step "5/7  Database Core Data (progetti, finestre)"
# ============================================================================
DATA_DIRS=(
    "$HOME/Library/Application Support/${APP_NAME}"
    "$HOME/Library/Containers/${BUNDLE_ID}"
    "$HOME/Library/Group Containers/group.${BUNDLE_ID}"
)
for d in "${DATA_DIRS[@]}"; do
    if [[ -e "$d" ]]; then
        rm -rf "$d" && ok "rimosso: $d" || warn "impossibile rimuovere: $d"
    else
        skip "non presente: $d"
    fi
done

# ============================================================================
step "6/7  Preferenze (UserDefaults, chiavi API)"
# ============================================================================
PREF_FILES=(
    "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
    "$HOME/Library/Preferences/${BUNDLE_ID}.plist.lockfile"
    "$HOME/Library/SyncedPreferences/${BUNDLE_ID}.plist"
    "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
)
# Anche eventuali file .plist all'interno della cartella ByHost
ls "$HOME/Library/Preferences/ByHost/${BUNDLE_ID}".* 2>/dev/null | while read -r f; do
    PREF_FILES+=("$f")
done
# Il daemon cfprefsd memorizza in cache i defaults — forziamo lo scarico.
defaults delete "$BUNDLE_ID" 2>/dev/null && ok "cache defaults pulita"
for f in "${PREF_FILES[@]}"; do
    if [[ -e "$f" ]]; then
        rm -rf "$f" && ok "rimosso: $f" || warn "impossibile rimuovere: $f"
    else
        skip "non presente: $f"
    fi
done

# ============================================================================
step "7/7  Log e cache"
# ============================================================================
EXTRA_PATHS=(
    "$HOME/Library/Logs/${APP_NAME}"
    "$HOME/Library/Logs/${BUNDLE_ID}"
    "$HOME/Library/Caches/${BUNDLE_ID}"
    "$HOME/Library/HTTPStorages/${BUNDLE_ID}"
    "$HOME/Library/WebKit/${BUNDLE_ID}"
    "$HOME/Library/Application Scripts/${BUNDLE_ID}"
)
for p in "${EXTRA_PATHS[@]}"; do
    if [[ -e "$p" ]]; then
        rm -rf "$p" && ok "rimosso: $p" || warn "impossibile rimuovere: $p"
    else
        skip "non presente: $p"
    fi
done

# ============================================================================
# Verifica finale
# ============================================================================
echo
echo "${BOLD}=========================================${RESET}"
echo "${BOLD}  Verifica finale${RESET}"
echo "${BOLD}=========================================${RESET}"
RESIDUI=$(find "$HOME/Library" /Applications \
    -maxdepth 4 \
    \( -iname "*${APP_NAME}*" -o -iname "*${BUNDLE_ID}*" \) \
    2>/dev/null)
if [[ -z "$RESIDUI" ]]; then
    echo "${GREEN}${BOLD}✓ Disinstallazione completa.${RESET} Nessun residuo trovato."
else
    echo "${YELLOW}Sono rimasti questi file (potresti volerli rimuovere a mano):${RESET}"
    echo "$RESIDUI" | sed 's/^/  /'
fi
echo
echo "${DIM}Suggerimento: Impostazioni di Sistema → Generali → Apri al login,${RESET}"
echo "${DIM}se vedi ancora una voce \"NoMoreChaos\" rotta, eliminala col tasto «−».${RESET}"
echo
read "REPLY?Premi Invio per chiudere."
