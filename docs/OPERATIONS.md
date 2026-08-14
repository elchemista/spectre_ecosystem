# Operations

## Campagna manuale da CLI

```bash
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem dispatch \
  --spectre-ref CORE_SHA \
  --profile full \
  --packages all \
  --campaign-id manual-YYYYMMDD
```

Usa uno SHA per campagne di release candidate. Branch e tag sono accettati per
diagnosi, ma uno SHA rende il report immutabile.

## Campagna parziale

```bash
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem dispatch \
  --spectre-ref CORE_SHA \
  --profile compat \
  --packages spectre_ledger,spectre_lab \
  --campaign-id ledger-lab-CORE_SHA
```

Il piano mantiene l'ordine dichiarato dal grafo. Ogni repository viene comunque
eseguito dal proprio workflow e non condivide filesystem o processi con gli
altri.

## Diagnosi

1. Apri il report aggregato.
2. Segui il `run_url` del repository fallito.
3. Identifica il job remoto fallito.
4. Correggi il repository proprietario del test o il core, secondo la causa.
5. Riesegui lo stesso job oppure crea una campagna esplicita.

Classi di errore centrali comuni:

- `github_http_401` o `github_http_403`: permessi App o secret errati;
- `github_http_404`: repository, workflow o branch non esistente;
- `campaign_discovery_timeout`: il workflow non espone il campaign ID nel
  `run-name`, oppure GitHub non ha creato il run;
- `workflow_wait_timeout`: il run satellite ha superato il limite registrato;
- risultato mancante: il job centrale è terminato prima di scrivere l'artifact.

## Modifica dei timeout

`timeout_minutes` in `ecosystem.json` limita l'attesa del singolo workflow
satellite. Aumentalo soltanto dopo aver verificato che il job remoto stia
progredendo; non usarlo per nascondere un deadlock. Il valore massimo è 50
minuti, così dispatch e lettura finale restano entro la durata del token
installazione GitHub App.

## Rotazione della GitHub App

1. genera una nuova private key dall'App;
2. sostituisci `SPECTRE_APP_PRIVATE_KEY` nel repository centrale;
3. esegui una campagna su un solo satellite;
4. revoca la chiave precedente;
5. esegui `doctor --github` e una campagna completa.

## Rimozione di un repository

Rimuovi prima il repository dal manifest e valida la PR. Dopo il merge, rimuovi
l'installazione GitHub App da quel repository. Non cancellare i report storici:
restano evidenza delle campagne precedenti.
