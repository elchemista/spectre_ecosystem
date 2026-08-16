# Changelog

## 0.1.0 - unreleased

### Added

- Registry chiuso dei nove repository satellite richiesti.
- CLI dependency-free per registry, matrice, report e snapshot.
- Matrice centrale che clona e testa tutti i repository pubblici contro il core
  richiesto, senza GitHub App o secret.
- Snapshot JSON pubblico con risultati di compatibilità e versioni Hex/GitHub,
  distribuito giornalmente tramite GitHub Pages.
- Documentazione italiana per configurazione, gestione e onboarding.

### Architecture

- Il core resta completamente indipendente dall'ecosistema.
- Il core resta una dipendenza normale fuori dalla CI centrale.
- Le librerie espongono soltanto l'override esplicito `SPECTRE_PATH`.
- Il repository centrale possiede la matrice e la pubblicazione dello stato.
