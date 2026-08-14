# Architecture

## Responsabilità

`spectre_ecosystem` possiede soltanto:

- registry dei repository e del loro ordine logico;
- osservazione delle release GitHub del core;
- invio dei workflow satellite;
- polling di run e job;
- aggregazione dei risultati.

Non possiede:

- codice o configurazione del core;
- strategia di test delle librerie;
- runtime, database o servizi dei satellite;
- checkout e patch delle dipendenze;
- ciclo di distribuzione dei repository.

## Ownership

```text
Core repository
  └── source, tag e release del core

Ecosystem repository
  └── registry, watch, dispatch, wait, report

Satellite repository
  └── exact-core checkout, dependency override, services e test gates
```

La dipendenza operativa va dal centrale verso le API GitHub. Non esiste alcuna
dipendenza runtime dal core verso l'orchestratore.

## Identità della campagna

Le campagne manuali usano un ID esplicito o generato. Il watcher usa
`core-release-<tag>`. Il CLI include lo stesso ID negli input di ogni satellite;
il `run-name` remoto lo espone e consente la correlazione senza stato globale.
La deduplicazione del watcher pagina fino a 1.000 run centrali e confronta l'ID
completo, evitando sia l'evizione rapida sia collisioni per prefisso.

La release viene prima risolta a SHA. Il report registra lo SHA passato ai
satellite, evitando che un branch mobile cambi significato durante la matrice.

## Delivery e osservazione

Il CLI chiede all'API di dispatch i dettagli del run. Poiché installazioni o
versioni API differenti possono ancora rispondere senza un ID, la correlazione
ha un fallback esplicito:

1. invia `workflow_dispatch`;
2. usa immediatamente il run ID restituito, quando presente;
3. altrimenti cerca il `campaign_id` nei run recenti del workflow target;
4. applica un timeout alla fase di discovery;
5. attende il completamento del run trovato;
6. legge i job e produce un risultato schema 1.

Un errore HTTP, un timeout o un risultato non-success produce un risultato
fallito; non viene promosso a successo ambiguo.

## Sicurezza

La matrice crea un token GitHub App nuovo per ogni repository target. Il token
non viene caricato come artifact e non viene inoltrato al workflow satellite.
Il satellite usa il proprio `GITHUB_TOKEN` con i permessi dichiarati nel proprio
file.

Il manifest è chiuso: non contiene shell, path, variabili ambiente o nomi di
runner. L'aggiunta di un repository non può quindi introdurre un comando nel
processo centrale.
