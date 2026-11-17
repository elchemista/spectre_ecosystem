# Changelog

## 0.1.0 — 2026-11-17

### Added

- Checkout coordinato della linea 0.4, comprese le dipendenze transitive e i
  relativi override espliciti; gli artifact e il feed conservano gli SHA testati.
- Verifica offline dello script di checkout nella CI locale dell'orchestratore.
- Catalogo della linea 0.4 fissato a SHA pubblicati per core e nove satelliti;
  default del workflow coerenti, con override espliciti branch/tag/SHA del core.
- Registry chiuso dei nove repository satellite richiesti.
- CLI dependency-free per registry, matrice, report e snapshot.
- Matrice centrale che clona e testa tutti i repository pubblici contro il core
  richiesto, senza GitHub App o secret.
- Snapshot JSON pubblico con risultati di compatibilità e versioni Hex/GitHub,
  distribuito giornalmente tramite GitHub Pages.
- Documentazione italiana per configurazione, gestione e onboarding.

### Fixed

- Il profilo `full` aggrega la coverage RAM e proiezione del core, usando gli
  stessi controlli della CI Spectre; le librerie mantengono i propri test.

### Architecture

- Il core resta completamente indipendente dall'ecosistema.
- Il core resta una dipendenza normale fuori dalla CI centrale.
- Le librerie espongono override espliciti `SPECTRE_PATH` e, quando necessario,
  `<NOME_PACCHETTO>_PATH` per i satelliti richiesti.
- Il repository centrale possiede la matrice e la pubblicazione dello stato.
