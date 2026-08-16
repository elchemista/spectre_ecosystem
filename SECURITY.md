# Security

## Confine di fiducia

La matrice clona ed esegue codice dai repository pubblici registrati. Per
questo motivo ogni libreria gira in un runner GitHub-hosted isolato, senza
secret e con permessi workflow `contents: read`.

I checkout usano `persist-credentials: false`; i comandi Mix non ricevono
`GITHUB_TOKEN`. Non aggiungere secret, credenziali cloud o runner self-hosted al
job `compatibility`.

Il job `publish` esegue soltanto il codice di `spectre_ecosystem` dal branch
protetto. Il job `deploy` è l'unico con `pages: write` e `id-token: write`.

## Dati pubblicati

Gli artifact contengono soltanto nomi repository, SHA, stato, durata e URL del
run. `status.json` aggiunge versioni pubbliche GitHub e Hex. Header HTTP, token
e output completo dei test non vengono copiati nel feed.

## Input

`ecosystem.json` è un registry revisionato e non accetta comandi shell. I nomi,
repository e ref sono validati prima di entrare nella matrice. Il workflow di
pubblicazione non parte sulle pull request.

## Segnalazioni

Segnala privatamente possibili vulnerabilità al proprietario del repository,
senza includere credenziali nei log o nelle issue pubbliche.
