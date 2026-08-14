# Contributing

1. Lavora su un branch dedicato.
2. Mantieni l'orchestratore indipendente dal runtime Spectre.
3. Non aggiungere comandi satellite, checkout locali o configurazioni di test al
   manifest centrale.
4. Ogni nuova repository deve avere il workflow remoto richiesto e dipendenze
   dichiarate senza cicli.
5. Aggiorna test, README e documentazione operativa insieme al contratto.
6. Esegui formatter, compilazione warning-free, suite e coverage prima della PR.

Le modifiche a manifest, workflow centrali, client GitHub e confini delle
credenziali richiedono la revisione del proprietario indicato in `CODEOWNERS`.
