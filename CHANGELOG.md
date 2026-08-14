# Changelog

## 0.1.0 - unreleased

### Added

- Registry chiuso dei nove repository satellite richiesti.
- CLI dependency-free per validazione, piano, dispatch, attesa, doctor e report.
- Orchestrazione GitHub-to-GitHub con token GitHub App per-repository.
- Watcher schedulato delle release GitHub del core con deduplicazione per tag.
- Report aggregato con stato dei job e link ai run satellite.
- Documentazione italiana per configurazione, gestione e onboarding.

### Architecture

- Il core resta completamente indipendente dall'ecosistema.
- I workflow satellite possiedono l'esecuzione e i gate di compatibilità.
- Il repository centrale non contiene un runner locale per le librerie.
