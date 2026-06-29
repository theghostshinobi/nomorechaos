#!/bin/bash

# Previeni errori silenziosi
set -euo pipefail

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== NoMoreChaos Packaging Script ===${NC}"

# 1. Verifica xcodebuild
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}Errore: xcodebuild non trovato. Assicurati che Xcode Command Line Tools siano installati.${NC}"
    exit 1
fi

# Trova la cartella principale del progetto
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

# Definizione percorsi
BUILD_DIR="${PROJECT_DIR}/build"
STAGING_DIR="${BUILD_DIR}/staging"
TEMP_DMG="${BUILD_DIR}/NoMoreChaos_temp.dmg"
FINAL_DMG="${PROJECT_DIR}/NoMoreChaos.dmg"
APP_NAME="NoMoreChaos"

echo -e "${BLUE}Pulizia delle build precedenti...${NC}"
rm -rf "${BUILD_DIR}"
rm -f "${FINAL_DMG}"

echo -e "${BLUE}Compilazione in corso (Release Configuration)...${NC}"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    clean build

# Trova il binario .app generato
BUILT_APP="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "${BUILT_APP}" ]; then
    echo -e "${RED}Errore: Impossibile trovare l'applicazione compilata in ${BUILT_APP}${NC}"
    exit 1
fi

echo -e "${GREEN}Compilazione completata con successo!${NC}"

echo -e "${BLUE}Preparazione dello staging installer...${NC}"
mkdir -p "${STAGING_DIR}"
cp -R "${BUILT_APP}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo -e "${BLUE}Creazione del file DMG temporaneo...${NC}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDRW \
    "${TEMP_DMG}"

echo -e "${BLUE}Conversione del DMG in formato compresso di produzione...${NC}"
hdiutil convert "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${FINAL_DMG}"

echo -e "${BLUE}Pulizia dei file temporanei...${NC}"
rm -rf "${STAGING_DIR}"
rm -f "${TEMP_DMG}"

if [ -f "${FINAL_DMG}" ]; then
    echo -e "${GREEN}=== Pacchetto DMG creato con successo in: ${FINAL_DMG} ===${NC}"
else
    echo -e "${RED}Errore nella generazione del file DMG finale.${NC}"
    exit 1
fi
