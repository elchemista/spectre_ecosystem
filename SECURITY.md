# Security

## Confine di fiducia

L'orchestratore tratta manifest, input CLI e risposte GitHub come dati non
fidati. Non valuta codice dai repository registrati e non accetta comandi nel
manifest.

I test delle librerie vengono eseguiti esclusivamente dai workflow posseduti da
quelle librerie. Ogni job centrale crea un token GitHub App limitato a un solo
repository satellite e lo usa soltanto per inviare e leggere quel workflow.

## Credenziali

- Il CLI legge token solo da `GH_TOKEN` o `GITHUB_TOKEN`.
- Nessun token è accettato come argomento CLI.
- Gli errori e i report non includono header, risposte integrali o credenziali.
- `SPECTRE_APP_PRIVATE_KEY` deve essere un Actions secret del solo repository
  centrale.
- `SPECTRE_APP_CLIENT_ID` può essere una Actions variable.
- I workflow satellite non ricevono la chiave privata della GitHub App.

## Permessi minimi

La GitHub App richiede sui repository satellite:

- Actions: read and write;
- Metadata: read-only.

Non concedere permessi su Contents, Issues, Pull requests o Administration. Il
watcher usa il token effimero del repository centrale soltanto per
avviare un altro workflow nello stesso repository.

## Segnalazioni

Segnala privatamente possibili vulnerabilità al proprietario del repository,
senza includere credenziali nei log o nelle issue pubbliche.
