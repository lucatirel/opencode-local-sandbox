# OpenCode Local Sandbox Template

Template Windows per usare un modello locale servito da `llama.cpp` con OpenCode confinato in una Docker Sandbox distinta per ogni progetto.

Questa repository contiene il **tooling**, non i progetti e non le dipendenze pesanti. `llama.cpp`, i modelli GGUF, i certificati privati e le cartelle di lavoro rimangono fuori da Git.

## Risultato finale

Una volta configurato il PC:

```powershell
.\sandbox.ps1 new "mia-app"
```

crea automaticamente una cartella Git sotto `Projects`, crea una sandbox dedicata, avvia `llama-server` se necessario, installa CA e configurazione OpenCode nella sandbox e apre OpenCode.

Per un progetto gia esistente:

```powershell
.\sandbox.ps1 open "C:\Projects\progetto-esistente"
```

La repository del template resta separata:

```text
C:\AI\llama.cpp\                       programma, modelli e certificati
C:\AI\opencode-local-sandbox\          questa repository
C:\Users\nome\Projects\mia-app\       progetto Git e workspace sandbox
C:\Users\nome\Projects\altra-app\     altro progetto, altra sandbox
```

Non bisogna creare progetti dentro `opencode-local-sandbox` e non bisogna copiare il template dentro i progetti.

## Architettura e isolamento

- `llama-server` gira sull'host Windows e ascolta soltanto su `127.0.0.1`.
- La sandbox raggiunge il server tramite `host.docker.internal` e HTTPS.
- La CA di sviluppo non viene resa attendibile globalmente da Windows: viene installata soltanto dentro ogni sandbox.
- Ogni progetto riceve una sandbox con nome stabile derivato da nome e percorso.
- Soltanto la cartella del progetto viene montata in scrittura.
- OpenCode, pacchetti installati e Docker Engine della sandbox rimangono nella microVM.
- La configurazione OpenCode viene generata e installata dentro la sandbox; non viene copiata nel progetto.
- La regola per `localhost:8080` e limitata alla singola sandbox tramite `--sandbox`.
- Modelli, chiavi, certificati e percorsi locali non vengono committati.

La sandbox protegge il resto del PC, ma OpenCode puo modificare o cancellare file non committati dentro il progetto. Fai commit frequenti.

## Requisiti del nuovo PC

Prima del bootstrap devono esistere:

- Windows e PowerShell;
- Git;
- `llama.cpp` compilato, preferibilmente con CUDA;
- almeno un modello `.gguf` dentro `llama.cpp\models`.

Il bootstrap puo installare tramite `winget` i due strumenti piccoli mancanti:

- Docker Sandboxes CLI (`sbx`);
- `mkcert`.

Non scarica modelli e non compila `llama.cpp`, perche percorso, GPU e modello sono scelte specifiche della macchina.

## Installazione da zero

Clona il template:

```powershell
git clone https://github.com/lucatirel/opencode-local-sandbox.git
Set-Location .\opencode-local-sandbox
Set-ExecutionPolicy -Scope Process Bypass
```

Avvia il bootstrap:

```powershell
.\sandbox.ps1 bootstrap
```

Il bootstrap:

1. verifica Git, `sbx` e `mkcert`;
2. propone di installare `sbx` o `mkcert` se mancano;
3. rileva il percorso storico `Desktop\Git\llama.cpp` oppure lo chiede;
4. rileva automaticamente il GGUF se ce n'e uno solo;
5. chiede la cartella generale dei progetti;
6. crea `config.local.ps1`, escluso da Git;
7. effettua il login a Docker Sandboxes quando necessario;
8. genera il certificato HTTPS senza installare una CA globale in Windows;
9. installa la CA soltanto nelle sandbox quando vengono create o aperte;
10. esegue il controllo `doctor`.

Su una nuova installazione di `sbx`, per la rete scegli **Locked Down** se vuoi il profilo piu restrittivo. Le regole aggiunte da questo template sono specifiche della singola sandbox. Un'eventuale policy globale gia esistente continua comunque ad applicarsi.

## Uso quotidiano

### Nuovo progetto

```powershell
Set-Location C:\AI\opencode-local-sandbox
.\sandbox.ps1 new "nome-progetto"
```

Il progetto nasce come repository Git vuota. Dentro OpenCode puoi quindi scrivere, per esempio:

> Stiamo creando XYZ. Definisci una struttura adatta, crea i file necessari, usa solo dipendenze pertinenti, esegui i test e inizializza il progetto in questa cartella.

Git e gia inizializzato dallo script: non chiedere all'LLM di creare un'altra repository annidata.

### Progetto esistente

```powershell
.\sandbox.ps1 open "C:\Projects\nome-progetto"
```

Se la relativa sandbox non esiste viene creata. Se esiste viene riutilizzata e la configurazione viene aggiornata.

### Server manuale

Normalmente `new` e `open` aprono una seconda finestra PowerShell e avviano il server quando non risponde. Per avviarlo manualmente:

```powershell
.\sandbox.ps1 server
```

### Diagnostica

```powershell
.\sandbox.ps1 doctor
```

## Comandi principali

```text
.\sandbox.ps1 help
.\sandbox.ps1 bootstrap
.\sandbox.ps1 doctor
.\sandbox.ps1 server
.\sandbox.ps1 new nome-progetto
.\sandbox.ps1 open C:\percorso\progetto
```

Gli script sotto `scripts\` espongono opzioni avanzate, per esempio `-NoAttach`, `-NoAutoStartServer`, `-NoGit` e un nome sandbox esplicito.

## Configurazione locale

`config.example.ps1` contiene tutti i default versionati. `config.local.ps1` contiene normalmente solo le differenze della macchina:

```powershell
$LlamaRoot = 'C:\AI\llama.cpp'
$ModelFile = 'Qwen3-8B-Q4_K_M.gguf'
$ProjectsRoot = 'C:\Projects'
```

Puoi aggiungere override, per esempio:

```powershell
$ContextSize = 24576
$SandboxMemory = '8g'
$SandboxCpus = 8
$ModelAlias = 'qwen3-8b-q4'
$OutputTokens = 2048
```

Un vecchio `config.local.ps1` con poche variabili continua a funzionare: prima vengono caricati i default, poi gli override locali.

## Rete e installazione delle dipendenze dei progetti

L'endpoint locale viene consentito automaticamente solo alla sandbox corrente:

```text
localhost:8080
```

Se usi una policy globale Locked Down e vuoi permettere package manager specifici, aggiungi in `config.local.ps1` soltanto gli host necessari:

```powershell
$AdditionalNetworkHosts = @(
    'registry.npmjs.org:443',
    'pypi.org:443',
    'files.pythonhosted.org:443'
)
```

Questi host vengono applicati alle sandbox aperte successivamente. Non usare `"**"` se vuoi mantenere un isolamento di rete significativo.

## Configurazione llama.cpp predefinita

I default attuali sono tarati sul setup verificato con RTX 4070 Laptop 8 GB e 16 GB RAM:

- Qwen3 8B Q4_K_M;
- contesto `32768`;
- KV cache `q4_0`;
- Flash Attention attiva;
- un solo slot;
- GPU layers `all`;
- thinking disabilitato;
- reasoning format `deepseek` per evitare tag `<think>` vuoti;
- Web UI disabilitata;
- HTTPS e bind a `127.0.0.1`.

Se la memoria non basta, prova prima:

```powershell
$ContextSize = 24576
```

nel file `config.local.ps1`.

## Configurazione OpenCode

Quando apri un progetto, lo script genera la configurazione effettiva in `.local\generated`, poi la installa nella home della sandbox:

```text
~/.config/opencode/opencode.json
```

In questo modo:

- il progetto non riceve un `opencode.json` artificiale;
- un `opencode.json` realmente appartenente al progetto puo comunque avere precedenza;
- ogni sandbox mantiene sessioni e stato separati;
- cambi di modello o contesto vengono propagati alla successiva apertura.

La configurazione predefinita usa `permission: allow`: OpenCode non chiede conferma per ogni operazione, ma resta confinato dalla sandbox. Cambiala in `ask` in `config.local.ps1` se preferisci approvazioni interattive:

```powershell
$OpenCodePermission = 'ask'
```

## Aggiornare il template

Dentro la repository del template:

```powershell
git pull
.\sandbox.ps1 doctor
```

Le sandbox esistenti ricevono la nuova configurazione quando le riapri.

## Migrazione dalla prima versione

La vecchia sandbox `agentbox-test` non viene rimossa automaticamente. Dopo aver verificato una nuova sandbox per un progetto, puoi elencare e rimuovere manualmente quella vecchia:

```powershell
sbx ls
sbx rm agentbox-test
```

`sbx rm` elimina lo stato della sandbox, non la cartella progetto sull'host, ma resta un'operazione irreversibile per i pacchetti e le sessioni conservati nella microVM.

## Risoluzione problemi

### Script PowerShell bloccati

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

### Sandbox non autenticata

```powershell
sbx login
```

### Server non raggiungibile

```powershell
.\sandbox.ps1 server
```

In un altro terminale, indicando esplicitamente la CA senza aggiungerla al trust globale di Windows:

```powershell
$CARoot = (& mkcert -CAROOT).Trim()
curl.exe --cacert "$CARoot\rootCA.pem" https://localhost:8080/v1/models
```

### Controllare le richieste di rete

Trova il nome con `sbx ls`, poi:

```powershell
sbx policy log NOME-SANDBOX --limit 20
```

### Certificato non attendibile

```powershell
.\scripts\generate-certs.ps1
.\sandbox.ps1 open "C:\percorso\progetto"
```

La seconda operazione reinstalla la CA nella sandbox.

## File della repository

```text
.
|-- sandbox.ps1
|-- config.example.ps1
|-- opencode.json
|-- AGENTS.md
|-- scripts
|   |-- bootstrap.ps1
|   |-- doctor.ps1
|   |-- generate-certs.ps1
|   |-- new-project.ps1
|   |-- open-project.ps1
|   |-- start-llama.ps1
|   |-- run-opencode.ps1
|   |-- setup-sandbox.ps1
|   `-- private\Common.ps1
|-- tests\static-tests.ps1
|-- .github\workflows\validate.yml
|-- .gitattributes
|-- .gitignore
`-- README.md
```

`run-opencode.ps1` e `setup-sandbox.ps1` restano come wrapper di compatibilita; per il normale utilizzo usa `sandbox.ps1`.
