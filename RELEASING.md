# Vydání nové verze SnapCastu

Návod pro toho, kdo SnapCast podepisuje, notarizuje a vydává. Výsledkem je DMG na [GitHub Releases](https://github.com/Dahutis/SnapCast/releases) a aktualizace, kterou si nainstalované kopie stáhnou samy přes Sparkle.

## Jednorázové nastavení

1. **Přístup k repu.** Potřebuješ právo zápisu do `Dahutis/SnapCast` (přidá tě Jakub jako collaboratora) a přihlášené GitHub CLI:
   ```bash
   brew install gh   # pokud ho nemáš
   gh auth login
   ```
2. **Certifikát Developer ID.** V Xcode → Settings → Accounts vyber tým NoxGames → Manage Certificates → **+** → *Developer ID Application*. Vytvořit ho může jen Account Holder týmu.
3. **Repo:**
   ```bash
   git clone https://github.com/Dahutis/SnapCast.git
   cd SnapCast
   ```
4. **Podpisový klíč pro Sparkle.** Od Jakuba dostaneš soubor `snapcast-sparkle-private-key`. Naimportuj ho do klíčenky:
   ```bash
   xcodebuild -resolvePackageDependencies -project SnapCast.xcodeproj -scheme SnapCast -derivedDataPath build/DerivedData
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account snapcast -f ~/Downloads/snapcast-sparkle-private-key
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account snapcast -p
   ```
   Poslední příkaz musí vypsat `reLJfq5NlMcvQ3GwFlampz5PAEyloVmgnjDfK5pPd6Y=`. Pak soubor s klíčem smaž z Downloads a z chatu nebo e-mailu, kterým přišel. Zálohu ať má jen správce hesel.

## Každé vydání

1. **Aktuální kód:** `git pull`
2. **Verze.** V `SnapCast/Info.plist` zvedni `CFBundleShortVersionString` (např. `1.2.0` → `1.3.0`) a `CFBundleVersion` o 1 (např. `3` → `4`). Sparkle porovnává `CFBundleVersion`, takže to číslo musí vždycky růst. Commitni a pushni.
   *Verze 1.2.0 (3) už je nastavená, u prvního vydání tenhle krok přeskoč.*
3. **Tým.** Otevři `SnapCast.xcodeproj` → target SnapCast → *Signing & Capabilities* → Team: **NoxGames**. Tuhle změnu necommituj.
4. **Archiv a notarizace.** *Product → Archive*. V Organizeru, který se otevře, zvol *Distribute App → Direct Distribution → Distribute*. Xcode aplikaci podepíše Developer ID a pošle ji Applu k notarizaci. Trvá to pár minut, Organizer ukazuje stav. Až bude hotovo, klikni na *Export* a ulož `SnapCast.app`, např. do `~/Desktop/SnapCast-export/`.
5. **Vrať změnu týmu:** `git checkout SnapCast.xcodeproj/project.pbxproj`
6. **Vydání:**
   ```bash
   scripts/release.sh --app ~/Desktop/SnapCast-export/SnapCast.app "Co je nového v téhle verzi"
   ```
   Skript zkontroluje, že aplikace je notarizovaná a má stejnou verzi jako `Info.plist`. Pak vytvoří DMG, podepíše ho klíčem pro Sparkle, vydá ho na GitHubu, aktualizuje `appcast.xml` a `Presentation/SnapCast.dmg` a commitne to.
7. **Zveřejnění:** `git push origin HEAD:main`. Teprve tímhle krokem se aktualizace dostane k lidem.
8. **Kontrola:** ve starší verzi SnapCastu dej Settings → *Check for Updates…*. Měla by nabídnout novou verzi.

## Když něco selže

| Hláška | Co s tím |
|---|---|
| `Release vX.Y.Z already exists` | Zapomněl jsi zvednout verzi (krok 2). |
| `App is … but Info.plist says …` | Archivoval jsi jiný stav kódu, než je v repu. Udělej `git pull` a archivuj znovu. |
| `does not have a ticket stapled` | Exportoval jsi dřív, než notarizace doběhla. V Organizeru počkej na stav *Ready* a exportuj znovu. |
| `spctl … rejected` | Aplikace není podepsaná Developer ID. Zkontroluj tým v kroku 3. |
| `Sparkle signing key not found` | Klíč není v klíčence, viz jednorázové nastavení, bod 4. |

Když skript selže **po** vytvoření GitHub release, release smaž (`gh release delete vX.Y.Z --repo Dahutis/SnapCast --cleanup-tag`) a spusť ho znovu.

## Bezpečnost klíče

Klíč pro Sparkle potvrzuje, že aktualizace pochází od nás. Kdo ho má, může všem uživatelům SnapCastu podstrčit vlastní „aktualizaci“. Proto ho nikdy necommituj do repa a neposílej nešifrovaně.

Když klíč ztratíš, další aktualizace už nevydáš a všichni by museli novou verzi jednou nainstalovat ručně z DMG.

## Poznámky k verzi 1.2.0

- Lidé s verzí 1.1.0 nebo starší nemají Sparkle. Verzi 1.2.0 si musí jednou nainstalovat ručně z DMG, další aktualizace už přijdou samy.
- Mění se bundle ID i tým v podpisu, takže macOS se každého jednou znovu zeptá na povolení nahrávání obrazovky.
