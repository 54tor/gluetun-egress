# gluetun-egress — sortie VPN en failover, fail-closed, pour une application derrière CGNAT

*Egress* = le trafic **sortant** : ce dépôt est la porte de sortie d'une application, et rien d'autre.

L'application ne voit qu'une interface (`eth0`), ne sait rien des VPN, et **ne peut jamais sortir
par l'Internet du host** : tout son trafic sortant passe par un gateway qui l'envoie dans le premier
VPN réellement fonctionnel, ou nulle part. L'entrée, elle, passe par un reverse proxy (Caddy, Traefik…).
Dans l'exemple fourni, chaque VPN porte un tunnel WireGuard sortant (`wgentryN`, un wireproxy dans
la pile du Gluetun N) vers un relais public, puis Caddy.

## Paramétrage en bref

Tout se règle par les variables du service `gateway` ; il n'y a rien d'autre à toucher.

| Quoi | Variable | Règle |
|---|---|---|
| **VPN de sortie** | `VPN_IPS` | Liste d'IP de conteneurs Gluetun séparées par des espaces. **L'ordre est la priorité** : le premier VPN en vie porte toute la sortie. Le code n'impose aucun maximum ; **3 en pratique**, parce que le DNS de l'application ne lit que les 3 premiers `nameserver` (limite de musl et de glibc). |
| **Port entrant principal** | `APP_PORT` + `INGRESS_IP` | **Un seul port**, ouvert à **une seule source** : le reverse proxy d'entrée. |
| **Autres entrées** | `ALLOW_IN` | Autant de couples `ip:port` que voulu, séparés par des espaces. Jamais un sous-réseau ni un port seul. |
| **Appels de l'application vers le LAN** | `ALLOW_OUT` | Couples `ip:port` (un Redis, par exemple). Vide : rien n'est joignable. |
| **Réseau** | `LAN_SUBNET` | Sous-réseau du réseau interne `vpn-gateway`. |
| **Sondes** | `PROBE_URLS`, `PROBE_INTERVAL`, `PROBE_TIMEOUT`, `FAIL_THRESHOLD`, `RISE_THRESHOLD` | Détection de panne et de retour d'un VPN (valeurs par défaut au §4). |
| **Qualité du serveur VPN** | `VPN_CHECK_*` (sur les Gluetun, pas sur le gateway) | Débit et latence d'un serveur, retest périodique, remplacement : câblage au §3.2.1, détail au §4.8. |

Exemple minimal, deux VPN et un port d'application :

```yaml
gateway:
  environment:
    APP_PORT: "8080"                       # INGRESS_IP -> 8080
    INGRESS_IP: 172.30.20.10
    LAN_SUBNET: 172.30.20.0/24
    VPN_IPS: 172.30.20.11 172.30.20.12     # le 1er est prioritaire
    ALLOW_IN: "172.30.20.10:8081"          # une entrée de plus (ex. canal d'administration)
    ALLOW_OUT: "172.30.20.20:6379"         # l'application appelle ce Redis
```

- [1. Architecture](#1-architecture)
- [2. Fichiers](#2-fichiers)
- [3. Installation et démarrage](#3-installation-et-démarrage)
- [4. Fonctionnement détaillé](#4-fonctionnement-détaillé)
- [5. Validation](#5-validation)
- [6. Tests de failover, failback et anti-fuite](#6-tests-de-failover-failback-et-anti-fuite)
- [7. Exploitation](#7-exploitation)
- [8. Dépannage](#8-dépannage)
- [9. Performances](#9-performances)
- [10. Choix techniques et limites](#10-choix-techniques-et-limites)

---

## 1. Architecture

```
                       Relais public (WireGuard)
        (tunnel 1)            (tunnel 2)            (tunnel 3)
          │                     │                     │
┌─ netns gluetun1 ──┐ ┌─ netns gluetun2 ──┐ ┌─ netns gluetun3 ──┐
│ wgentry1          │ │ wgentry2          │ │ wgentry3          │
│ tun0 → NordVPN    │ │ tun0 → Proton     │ │ tun0 → custom     │
│ .10.11  │  .20.11 │ │ .10.12  │  .20.12 │ │ .10.13  │  .20.13 │
└────┬────────▲─────┘ └────┬────────▲─────┘ └────┬────────▲─────┘
     │        │            │        │            │        │
 frontend 172.30.10.0/24 ──┴────────┼────────────┴────────┼──── Caddy .10.10
                                    │                     │
 vpn-gateway 172.30.20.0/24 (internal) ─────────┬─────────┴──── Caddy .20.10
                                                │
                           ┌─ netns gateway ────┴───────────────────────┐
                           │ eth0 172.30.20.2      (seule interface)    │
                           │ route par défaut : .11 | .12 | .13 | unreachable
                           │ sondes : uid 64101→table 101 (.11)         │
                           │          uid 64102→table 102 (.12)         │
                           │          uid 64103→table 103 (.13)         │
                           │ nftables « inet vpngw » (fail-closed)      │
                           │  └─ app (network_mode: service:gateway)    │
                           └────────────────────────────────────────────┘
```

| Flux | Chemin |
|---|---|
| Entrant | relais → tunnel WireGuard → `wgentryN` (dans le netns de `gluetunN`) → `172.30.10.10:80` (Caddy) → `172.30.20.2:APP_PORT` (app) |
| Sortant de l'app | app → route par défaut du gateway → `gluetunN` (FORWARD vers `tun0` + MASQUERADE) → VPN N → Internet |
| Sortant de Caddy | réseau `frontend` → Internet du host (Caddy n'a pas besoin des VPN) |
| Sortant de wgentry | `tun0` de son Gluetun → VPN N → relais (UDP) |

### Plan d'adressage

| Réseau | Sous-réseau | gateway | caddy | gluetun1 | gluetun2 | gluetun3 |
|---|---|---|---|---|---|---|
| `frontend` | 172.30.10.0/24 | — | .10 | .11 | .12 | .13 |
| `vpn-gateway` (`internal: true`) | 172.30.20.0/24 | .2 | .10 | .11 | .12 | .13 |

Les ponts Docker (`.1`) appartiennent au host. `vpn-gateway` est `internal` : Docker n'y installe
aucune route vers l'extérieur et isole le pont côté host.

### Priorité des VPN

| Priorité | Service | Fournisseur | Sélection |
|---|---|---|---|
| 1 | `gluetun1` | NordVPN (WireGuard) | `SERVER_CITIES=London` |
| 2 | `gluetun2` | Proton VPN (WireGuard) | `SERVER_COUNTRIES=France` |
| 3 | `gluetun3` | Profil WireGuard (fournisseur `custom`) | endpoint fixe |

**Comment choisir l'ordre.** C'est l'ordre de `VPN_IPS` dans le service `gateway`, et il compte à deux titres :

- le **premier VPN en vie porte toute la sortie** de l'application : mets en tête le plus stable, ou celui dont
  l'adresse de sortie doit rester la même ;
- **un VPN qui a une capacité que les autres n'ont pas passe devant.** Seul un fournisseur qui redirige un port
  peut recevoir de l'entrant ; l'application qui en a besoin le place en priorité 1. Les
  autres ne font que de la sortie et de l'entrée par le relais.

L'exemple ci-dessus est un exemple : l'ordre Nord, Proton, custom n'a de sens que pour cette machine.

### Contraintes Docker qui ont façonné la topologie

- **`network_mode: service:gateway`** fait partager à l'app tout le namespace réseau du gateway :
  toutes ses interfaces, ses routes, son firewall, **et son `/etc/resolv.conf`** (Docker réutilise le
  même fichier, vérifiable avec `docker inspect -f '{{.ResolvConfPath}}'` sur les deux conteneurs).
  `networks:`, `ports:` et `dns:` sont interdits sur l'app.
- Chaque réseau Docker du gateway ajouterait une interface visible par l'app. Pour que l'app ne voie
  que `eth0`, **le gateway n'est que sur `vpn-gateway`**. Conséquence : l'app n'est pas joignable sur
  `frontend` ; **Caddy rejoint donc aussi `vpn-gateway`** et joint l'app en direct (L2) sur
  `172.30.20.2`, sans jamais passer par un Gluetun.
- Le trafic de l'app est du **trafic local** (chaîne `output`) pour le gateway, pas du `forward`.
  `ip_forward` y est donc inutile et vaut 0. Le forwarding a lieu dans les Gluetun.

---

## 2. Fichiers

| Fichier | Rôle |
|---|---|
| `gateway/Dockerfile` | Alpine + `iproute2`, `nftables`, `curl`, `su-exec` |
| `gateway/entrypoint.sh` | Firewall, tables de sonde, DNS, boucle de santé et de failover |
| `gateway/rules.nft` | Firewall nftables du namespace gateway/app (ensembles `allow_in` et `allow_out`) |
| `gateway/vpn-check.sh` | Sonde de santé des Gluetun (débit, latence, remplacement du serveur). Livrée dans l'image, déposée dans le volume `gateway-state` |
| `gluetun/post-rules-N.txt` | Forwarding + NAT gateway → `tun0` dans le Gluetun N (priorité N) |
| `host/vpngw-firewall.sh`, `.service`, `vpngw.conf.example` | Service hôte : règle `DOCKER-USER` contre la fuite au démarrage d'un Gluetun (§4.6) |
| `tools/set-addressing.sh` | Change le plan d'adressage de toute la pile d'un coup (§7) |
| `example/docker-compose.yml` | Une pile complète d'exemple : 3 Gluetun, 3 `wgentry` (wireproxy, un tunnel WireGuard vers le relais par Gluetun), Caddy, gateway, application |
| `example/.env.example` | Modèle de `.env` de l'exemple |
| `example/caddy/Caddyfile` | Site `:80` Caddy → `http://172.30.20.2:APP_PORT`, confiance aux Gluetun (`X-Forwarded-For`) |
| `.env`, `.env.vpn1`, `.env.vpn2`, `.env.vpn3`, `wgentry/wgN.conf` | Valeurs réelles, **secrets**, droits 600 — jamais versionnés |

Les chemins de ce document qui commencent par `docker-compose.yml`, `.env*` ou `caddy/` sont ceux de `example/`.

### Image publiée

Chaque tag `vX.Y.Z` publie `ghcr.io/54tor/gluetun-egress-gateway:X.Y.Z` (et `X.Y`, `X`, `latest`), construite par
`.github/workflows/image.yml` ; un push sur `main` publie `edge`. Version courante : **1.0.0**. Pour l'utiliser à la place de `build: ../gateway`,
mettre `image: ghcr.io/54tor/gluetun-egress-gateway:latest` dans le service `gateway`.

**Construire l'image soi-même** (dépôt : <https://github.com/54tor/gluetun-egress>) :

```sh
docker build -t gluetun-egress-gateway https://github.com/54tor/gluetun-egress.git#v1.0.0:gateway        # sans cloner
git clone https://github.com/54tor/gluetun-egress.git && docker build -t gluetun-egress-gateway gluetun-egress/gateway
cd gluetun-egress/example && docker compose up -d --build                                              # le compose construit `gateway`
```

`#v1.0.0:gateway` : la révision (tag, branche ou commit), puis le sous-dossier du contexte. Le build n'a besoin d'aucun secret ; le
CLI d'Ookla n'est pas téléchargé à la construction (§4.8).

Première publication refusée (`permission_denied: write_package`) : le paquet existe déjà sans être lié au dépôt (créé à la main, ou
sans le label `org.opencontainers.image.source`). Sur GitHub : Packages, `gluetun-egress-gateway`, Package settings, « Manage Actions
access », ajouter le dépôt avec le rôle Write ; ou supprimer le paquet vide et relancer le job. Le workflow demande déjà
`packages: write` ; un réglage de l'organisation (Settings, Actions, Workflow permissions) peut le brider.

### Brancher ce gateway sur une autre application

Le gateway ne connaît pas l'application : il en connaît le **port** et ce qu'elle a le droit d'appeler.
Variables du service `gateway` :

| Variable | Rôle |
|---|---|
| `APP_PORT` | Port d'écoute de l'application ; seul le reverse proxy d'entrée (`INGRESS_IP`, Traefik, Caddy…) peut l'ouvrir |
| `ALLOW_IN` | Ouvertures entrantes en plus : couples `ip:port` séparés par des espaces (ex. `172.30.20.11:4041`) |
| `ALLOW_OUT` | Services du LAN que l'application peut appeler : couples `ip:port` (ex. `172.30.20.20:6379` pour un Redis) |
| `LAN_SUBNET`, `INGRESS_IP`, `VPN_IPS` | Plan d'adressage (voir plus haut) ; l'ordre de `VPN_IPS` est la priorité |

Sans `ALLOW_OUT`, l'application ne peut joindre aucun service du réseau `vpn-gateway`, et c'est voulu.

**Exemple : une application à deux ports.** `4040` est le port principal (`APP_PORT`), `4041` un port de contrôle
appelé par le proxy et par un client autonome sur `gluetun1` ; elle appelle un Redis.

```yaml
gateway:
  environment:
    APP_PORT: "4040"                                  # proxy d'entrée (172.30.20.10) -> 4040
    ALLOW_IN: "172.30.20.10:4041 172.30.20.11:4041"   # proxy et client (gluetun1) -> 4041
    ALLOW_OUT: "172.30.20.20:6379"                    # l'application -> Redis
```

Chaque couple devient une ligne de l'ensemble nftables `allow_in` ou `allow_out` : un autre port du même hôte,
ou le même port d'un autre hôte, reste fermé.

Versions supposées et testées : Docker Engine 29.8.1 (≥ 28 requis pour
`com.docker.network.endpoint.sysctls`), Docker Compose 5.5.1 (≥ 2.24 pour `depends_on.restart`),
Gluetun **v3.41.3** (comportement vérifié dans son code source), wireproxy, Caddy et Alpine en images non épinglées (`latest`). Le comportement de Gluetun
décrit ici a été vérifié dans son code source v3.41.3 ; revérifier `post-rules.txt` en cas de montée
de version majeure.

---

## 3. Installation et démarrage

### 3.1 `.env`

```sh
cp .env.example .env && chmod 600 .env
```

| Variable | Défaut | Rôle |
|---|---|---|
| `TZ` | `Europe/Paris` | Fuseau des Gluetun |
| `APP_PORT` | `8080` | Port d'écoute de l'app (utilisé par Caddy et par le firewall du gateway) |
| `PROBE_URLS` | `https://9.9.9.9/ https://8.8.8.8/` | Cibles des sondes, par IP (aucune dépendance DNS). Une seule réponse suffit, quel que soit le code HTTP |
| `EGRESS_MODE` | `failover` | `failover` : le premier VPN en vie porte tout. `balance-dest` : répartition entre tous les VPN en vie, une destination gardant le même VPN (poser `EGRESS_HASH_POLICY=0`). `balance-flow` : répartition par connexion, l'IP de sortie varie d'une connexion à l'autre (`EGRESS_HASH_POLICY=1`). Un VPN mort est retiré de la route à `FAIL_THRESHOLD` ; ses connexions meurent. |
| `PROBE_INTERVAL` | `5` | Secondes entre deux cycles de sondes |
| `PROBE_INTERVAL_DOWN` | `1` | Secondes entre deux cycles tant qu'aucun VPN n'est validé en IPv4 : la première sortie arrive après `RISE_THRESHOLD` secondes au lieu de `RISE_THRESHOLD × PROBE_INTERVAL` |
| `PROBE_TIMEOUT` | `4` | Timeout de chaque requête de sonde |
| `FAIL_THRESHOLD` | `3` | Échecs consécutifs avant de déclarer un VPN mort |
| `LOG_REMINDER` | `600` | Secondes entre deux rappels dans le journal d'un VPN qui reste hors service : le gateway journalise une ligne quand un VPN change d'état (hors service, revenu), pas une par sonde |
| `RISE_THRESHOLD` | `3` | Succès consécutifs avant de le réintégrer |
| `VPN_CHECK_APIKEY` | — | Clé d'API du serveur de contrôle de chaque Gluetun, présentée par `vpn-check.sh` pour changer de serveur. Obligatoire dans l'exemple. Voir §3.2.1 |
| `VPN_CHECK_RECHECK_SECONDS` | `3600` | Retest périodique du débit et de la latence d'un serveur VPN, en secondes (`0` : jamais, un serveur validé n'est retesté que si l'IP change). Ex. `1800`. Voir §3.2.1 |

### 3.2 `.env.vpnN`

Un fichier par Gluetun, dans l'ordre de priorité. Ne jamais y définir `VPN_INTERFACE` ni `FIREWALL_*`
(fixés par le compose). `chmod 600 .env.vpn*`.

**NordVPN** — la clé WireGuard est la clé privée NordLynx (pas le token d'accès) ; l'adresse
`10.5.0.2/32` est le défaut Gluetun :
```dotenv
VPN_SERVICE_PROVIDER=nordvpn
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=...
SERVER_CITIES=London
```

**Proton VPN** — adresse par défaut `10.2.0.2/32` :
```dotenv
VPN_SERVICE_PROVIDER=protonvpn
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=...
SERVER_COUNTRIES=France
```

**Profil WireGuard quelconque** — fournisseur `custom`, à recopier depuis le fichier
`.conf` fourni par le fournisseur :
```dotenv
VPN_SERVICE_PROVIDER=custom
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=...        # [Interface] PrivateKey
WIREGUARD_ADDRESSES=10.x.x.x/32  # [Interface] Address, IPv4 seulement
WIREGUARD_PUBLIC_KEY=...         # [Peer] PublicKey
WIREGUARD_ENDPOINT_IP=203.0.113.10  # [Peer] Endpoint résolu en IP (getent ahostsv4 <nom>)
WIREGUARD_ENDPOINT_PORT=51820
```
Gluetun v3.41.3 exige une **IP** d'endpoint (pas de nom d'hôte) et refuse une adresse IPv6
d'interface quand l'IPv6 n'est pas supportée (voir §4.5). La ligne `DNS =` du profil est ignorée : Gluetun
utilise son propre DNS.

**Filtres de serveurs** : `SERVER_COUNTRIES`, `SERVER_CITIES`, etc. se **cumulent** (ET logique).
`SERVER_COUNTRIES=Spain,Italy` + `SERVER_CITIES=London` ne sélectionne aucun serveur. Utiliser un seul
type de filtre, avec des valeurs connues de Gluetun pour ce fournisseur (Gluetun refuse une ville ou
un pays inconnu). Le serveur est tiré au hasard parmi ceux qui passent le filtre : un pays très
fourni (Royaume-Uni) sortira plus souvent.

### 3.2.1 Sonde de qualité des Gluetun (`vpn-check.sh`)

Facultatif mais recommandé : il écarte les serveurs lents avant que la pile démarre, et, avec
`VPN_CHECK_RECHECK_SECONDS`, ceux qui se dégradent ensuite. À faire pour **chaque** Gluetun, dans le `docker-compose.yml` :

1. **Volume partagé** : déclarer `gateway-state` en volume racine, le monter dans le gateway sur `/run/gateway`, et dans
   chaque Gluetun sur `/gateway-state` en lecture seule, plus son propre volume de mesure `measure-vpnN` sur `/gateway-measure` (seul dossier où il écrit). Le gateway y dépose `vpn-check.sh` (livré dans son image) et la
   liste des tunnels en vie. Aucun fichier à copier, aucun socket Docker.
2. **Sonde de santé** du Gluetun : `healthcheck.test: ["CMD", "sh", "/gateway-state/vpn-check.sh"]`, avec
   `interval: 30s`, `timeout: 60s`, `retries: 3`, `start_period: 4m`, `start_interval: 10s`.
3. **Serveur de contrôle** : poser `HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000` (boucle locale seulement) et
   `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE='{"auth":"apikey","apikey":"<clé>"}'`, avec la même `<clé>` dans
   `VPN_CHECK_APIKEY` (variable d'environnement du Gluetun, lue par `vpn-check.sh` qui l'envoie dans l'en-tête
   `X-API-Key`). Le rôle par défaut couvre toute l'API : sans la clé, toute requête est refusée (401, testé en v3.41.3).
   Dans l'exemple, la clé vient de `VPN_CHECK_APIKEY` du `.env`, obligatoire.
4. **Nom du tunnel** : `VPN_CHECK_NAME=vpn1` sur le premier Gluetun de `VPN_IPS`, `vpn2` sur le deuxième, etc.
   Requis pour le retest, inutile sans.
5. **Retest** (actif par défaut, 3600) : `VPN_CHECK_RECHECK_SECONDS=1800` sur chaque Gluetun, ou dans le `.env` si le compose le
   transmet comme celui de l'exemple.

`example/docker-compose.yml` est câblé ainsi. Seuils, mémoire des IP recalées et garde-fou du dernier tunnel : §4.8.

### 3.3 Entrée : tunnels WireGuard vers un relais

L'entrée ne passe par aucun service tiers : chaque Gluetun porte un tunnel WireGuard **sortant** vers un relais public
(un petit serveur à IP fixe) qui reçoit les clients et les renvoie dans le tunnel. La pile n'a ni IP publique ni
port ouvert.

**Sur le relais** (un VPS Linux avec `wireguard-tools` et Caddy ; modèles dans `example/relay/`) :

1. Générer une paire de clés pour le relais et une par tunnel : `wg genkey | tee relais.key | wg pubkey > relais.pub`,
   idem pour `wg1`, `wg2`, `wg3`.
2. `example/relay/wg0.conf.example` → `/etc/wireguard/wg0.conf` : clé privée du relais, un `[Peer]` par tunnel
   (clé publique du tunnel, `AllowedIPs = 10.99.N.2/32`), puis `wg-quick up wg0`. Ouvrir UDP 51820 et TCP 80/443.
3. `example/relay/Caddyfile` → Caddy du relais, avec le nom d'hôte public. Il envoie vers `10.99.1.2:80 10.99.2.2:80
   10.99.3.2:80` en `lb_policy first`, avec une sonde `/healthz` : le premier tunnel en vie sert, les autres sont de
   secours. Il pose `X-Forwarded-For` avec l'adresse réelle du client.

**Sur la pile**, pour chaque tunnel N :

1. `cp wgentry/wgN.conf.example wgentry/wgN.conf`, puis renseigner la clé privée du tunnel, la clé publique du relais
   et son `Endpoint`.
2. `chown 65532 wgentry/wgN.conf && chmod 600 wgentry/wgN.conf` : `wgentryN` tourne en uid 65532, sans capacité.

`wgentryN` est un wireproxy (WireGuard en espace utilisateur) dans le namespace de `gluetunN` : ses paquets UDP partent
par `tun0`, donc par le VPN N. Il écoute sur le port 80 **côté WireGuard** et relaie vers Caddy, `172.30.10.10:80`.
Mettre l'IP, pas `caddy` : le DNS de Gluetun ne résout pas les noms Docker.

### 3.4 Démarrer

Récupérer le dépôt (`git clone --branch v1.0.0 https://github.com/54tor/gluetun-egress.git`), puis, depuis `example/` (copier d'abord
`example/.env.example` en `.env`, et créer les trois `.env.vpnN`) :

```sh
docker compose up -d --build
docker compose ps
docker compose logs -f gateway
```

Ordre imposé par `depends_on` : chaque `wgentryN` attend que `gluetunN` soit *healthy* ; l'app
attend que le gateway soit *healthy*. **Healthy, pour le gateway, signifie « firewall fail-closed
chargé », pas « un VPN est up »** : l'app peut démarrer sans risque avant qu'un VPN soit validé ; elle
n'a simplement pas d'Internet tant que c'est le cas.

Au premier démarrage, NordVPN et un profil `custom` peuvent enchaîner plusieurs tentatives avant un handshake
WireGuard réussi (5 à 11 observées) : c'est normal, Gluetun change de serveur et réessaie.

### 3.5 Remplacer l'application

Dans `docker-compose.yml`, remplacer l'image `traefik/whoami` du service `app` et sa `command`, en
gardant `network_mode: "service:gateway"` et `depends_on`. L'application doit écouter sur
`APP_PORT` (toutes interfaces ou `172.30.20.2`). Ne lui ajouter ni `networks:`, ni `ports:`, ni `dns:`.

---

## 4. Fonctionnement détaillé

### 4.1 Gateway (`gateway/entrypoint.sh`)

Au démarrage, dans cet ordre :

1. **Firewall d'abord** (`rules.nft`), avant toute modification de route : le namespace est
   fail-closed dès la première milliseconde.
2. **Route par défaut `unreachable`** : aucune sortie tant qu'aucun VPN n'est validé.
3. **Tables de sonde** : pour le VPN n° *i* de `VPN_IPS`, table `100+i` avec
   `default via <IP du Gluetun i>`, et règle `ip rule … uidrange 64100+i lookup 100+i` (priorité
   `1000+i`). Une règle finale (priorité `1999`) rend `unreachable` toute sonde dont la table aurait
   perdu sa route : une sonde ne retombe jamais sur la table `main`, donc jamais sur un autre VPN
   (pas de faux positif).
4. **DNS** : réécrit `/etc/resolv.conf` (partagé avec l'app) avec un `nameserver` par Gluetun et
   `options timeout:2 attempts:2`, puis, à chaque bascule IPv4, avec le seul Gluetun actif.

Puis, en boucle toutes les `PROBE_INTERVAL` secondes :

- **Sondes en parallèle**, une par VPN : `su-exec <uid> curl https://9.9.9.9/` (puis
  les autres `PROBE_URLS`). Grâce à l'UID, chaque sonde passe **par son VPN**, quelle que soit la
  route active. Le succès prouve que le Gluetun est joignable, que son tunnel fonctionne et
  qu'Internet répond à travers lui (Gluetun ne forwarde que vers `tun0`).
- **Un `ping` du Gluetun passe avant les URLs** (deux essais : un paquet perdu ne vaut pas une
  panne). Sans réponse, le VPN est compté en échec tout de suite (`injoignable`), sans attendre le
  timeout de chaque URL : un conteneur arrêté est détecté en `FAIL_THRESHOLD × (PROBE_INTERVAL + 2 s)`.
  Un Gluetun qui répond au ping mais dont l'URL échoue est journalisé `joignable mais tunnel trop
  lent` (timeout `PROBE_TIMEOUT`) ou `joignable mais aucune sortie Internet via son tunnel`.
- **Hystérésis** : un VPN passe *down* après `FAIL_THRESHOLD` échecs consécutifs et *up* après
  `RISE_THRESHOLD` succès consécutifs.
- **Choix** : en `failover`, le premier VPN *up* dans l'ordre de `VPN_IPS` ; en `balance-*`, tous les VPN *up* en route multipath à poids égal (`/run/gateway/active` vaut alors `vpn1,vpn2`) ; aucun → `unreachable`.
- La route est **ré-appliquée à chaque cycle** (auto-réparation si elle a été modifiée), l'état est
  écrit dans `/run/gateway/active` (`vpn1`, `vpn2`, `vpn3` ou `none`) et chaque changement est loggé
  (`sortie active -> …`).

En `failover` (défaut), un seul VPN porte le trafic à un instant donné ; la répartition n'existe qu'en `balance-*`.

**Connexions existantes** : lors d'une bascule, elles partent vers un autre VPN avec une autre IP
source ; le serveur distant répond par un RST et elles meurent. Les nouvelles connexions utilisent
le VPN actif. Le gateway ne fait aucun NAT, donc pas besoin de `conntrack`.

**`rp_filter` à 0** (sysctl `all` dans le compose, `eth0` via
`com.docker.network.endpoint.sysctls`) : en état `none`, la table `main` n'a qu'une route
`unreachable` ; avec `rp_filter` actif, le noyau jetterait les réponses des sondes et **aucun VPN ne
pourrait jamais remonter**. Sans risque ici : une seule interface.

### 4.2 Firewall du gateway (`gateway/rules.nft`)

Une seule table, `inet vpngw` (les règles NAT du DNS embarqué Docker ne sont pas touchées).

| Chaîne | Politique | Règles |
|---|---|---|
| `input` | drop | `lo` ; `established,related` ; découverte de voisins IPv6 seulement (rien d'autre n'entre en IPv6) ; **seul le proxy d'entrée (`INGRESS_IP`, 172.30.20.10) peut ouvrir une connexion, sur `APP_PORT`, plus les couples de `ALLOW_IN`** |
| `forward` | drop | aucune |
| `output` | drop | `127.0.0.11` drop (DNS embarqué Docker) ; `lo` ; `established,related` ; découverte de voisins IPv6 ; rien hors `eth0` ; DNS (53) seulement vers les Gluetun ; tout autre 53/853 drop ; ping vers les Gluetun ; rien d'autre vers le LAN Docker (IPv4 et IPv6), hors `ALLOW_OUT` (couples du LAN seulement : un couple public suit la règle Internet) ; **Internet seulement si le next-hop routé est un Gluetun** (`rt ip nexthop @nexthops` et `rt ip6 nexthop @nexthops6`) |

La dernière règle bloque toute sortie par une route qui ne passerait pas par un Gluetun, même si
quelqu'un ajoutait `default via 172.30.20.1` dans le namespace.

### 4.3 Gluetun (`gluetun/post-rules-N.txt`)

Comportement de Gluetun v3.41.3 (vérifié dans le code) :

- Politiques `INPUT`, `OUTPUT`, `FORWARD` à **DROP** (IPv4 et IPv6).
- Les sous-réseaux **directement attachés** (`frontend`, `vpn-gateway`) sont autorisés
  automatiquement en entrée et en sortie, avec une règle `ip rule … to <subnet> lookup main`
  (priorité 98) qui garantit que les réponses vers le gateway ne partent pas dans le tunnel.
- **`FIREWALL_OUTBOUND_SUBNETS`** : positionné sur `frontend` et `vpn-gateway`, il garantit que
  `wgentryN` joint le proxy d'entrée et que le gateway reste joignable depuis la pile du VPN. Gluetun
  autorise déjà les réseaux attachés ; la variable ajoute une route via la passerelle par défaut (table 199) et
  rend ce besoin explicite. ⚠️ à confirmer : retirer la variable et rejouer §6 dira si elle est strictement requise.
- **`FIREWALL_INPUT_PORTS` ne gère que l'`INPUT`**, jamais le forwarding.
- `post-rules.txt` : une commande par ligne, seules les lignes commençant par `iptables`,
  `iptables-nft`, `iptables-legacy`, `ip6tables…` sont exécutées, après les règles de Gluetun.
- `VPN_INTERFACE=tun0` est forcé pour que le nom soit le même en OpenVPN et en WireGuard (défaut
  WireGuard : `wg0`).

Contenu (exemple gluetun1, `.11` ; `.12` et `.13` pour les autres) :

| Règle | Effet |
|---|---|
| `-P FORWARD DROP` | Réaffirme la politique |
| `-I INPUT -i eth+ -d 172.30.20.11 -j gateway-seul`, la chaîne portant `! -s 172.30.20.2 -j DROP` | Seul le gateway peut joindre ce Gluetun sur `vpn-gateway` |
| `-I OUTPUT -d 172.30.10.10 -p tcp -j proxy-owner`, la chaîne portant `-m owner ! --uid-owner 65532 -j DROP` | Seul `wgentry` (uid 65532, `nonroot` de son image) joint le proxy d'entrée, **sur tous ses ports** |
| `-A FORWARD -i eth+ -s 172.30.20.2 -o tun0 -j ACCEPT` | Forward gateway → tunnel **uniquement** |
| `-A FORWARD -i tun0 -o eth+ -d 172.30.20.2 … ESTABLISHED,RELATED` | Retour |
| `-t nat -A POSTROUTING -s 172.30.20.2 -o tun0 -j MASQUERADE` | NAT vers le tunnel |
| `-t mangle … TCPMSS --clamp-mss-to-pmtu` (2 sens) | Évite les problèmes de MTU (1500 côté Docker, ~1420 dans le tunnel) |

Si le tunnel tombe, le noyau route le paquet forwardé vers `eth` au lieu de `tun0` : il ne matche
plus la règle `-o tun0` et la politique DROP le jette. **Aucune fuite possible par un Gluetun.**

Le proxy d'entrée fait confiance à l'adresse de chaque Gluetun (c'est par là qu'arrive `wgentryN`) et y croit
les en-têtes d'adresse cliente (`X-Forwarded-For`). Tout processus logé dans la pile d'un Gluetun sort sous cette
même adresse : seul l'uid les distingue. Sans cette règle, un tel processus poserait l'adresse de son choix. Elle
couvre **tous les ports** du proxy : limitée au port 80, elle laissait ouverte toute entrée de plus (un canal
d'administration, par exemple), que le proxy croit de la même façon.

### 4.4 DNS

- `/etc/resolv.conf` de l'app = celui du gateway : au démarrage `nameserver 172.30.20.11`, `.12`, `.13` ; dès
  qu'un VPN est actif, le seul `nameserver` de ce VPN (les fournisseurs inactifs ne voient pas les noms résolus).
  Sans VPN actif, le fichier garde son dernier contenu.
- Chaque Gluetun sert du DNS sur `:53` (toutes interfaces) et résout en DNS-over-TLS **dans son
  tunnel**. Si son tunnel est coupé, il ne répond plus et le client passe au serveur suivant (musl
  interroge en parallèle, glibc séquentiellement avec timeout de 2 s).
- Tout DNS vers une autre destination (8.8.8.8, 127.0.0.11, …) est refusé par nftables. Le DNS
  embarqué de Docker (`127.0.0.11`) est bloqué car il résout via le resolver du host.
- Le DoH d'une application passe par le VPN actif, comme tout son trafic HTTPS.
- musl et glibc n'utilisent que les **3 premiers** `nameserver` : au-delà de 3 VPN, les suivants
  n'ont pas de DNS de secours.
- Protection anti-rebinding de Gluetun : un nom public résolu vers une IP privée est bloqué.

### 4.5 IPv6

Facultative, et fail-closed comme l'IPv4 : sans `VPN_IPS6`, l'ensemble `@nexthops6` est vide, aucune route IPv6
n'est posée et toute sortie IPv6 est refusée.

- **Adressage** : le réseau `vpn-gateway` porte aussi un sous-réseau ULA (`fd30:20::/64` dans l'exemple),
  `enable_ipv6: true`.
- **NAT66** : Proton ne donne qu'une adresse IPv6 `/128` par tunnel. Chaque Gluetun traduit l'adresse ULA du
  gateway vers `tun0` (`ip6tables … MASQUERADE` dans `post-rules-N.txt`), comme en IPv4.
- **Un Gluetun a de l'IPv6 si** son `.env.vpnN` porte une adresse IPv6 dans `WIREGUARD_ADDRESSES`
  (`10.2.0.2/32,2a07:b944::2:2/128` pour Proton) **et** que le serveur choisi la route : ⚠️ certains serveurs Proton
  n'en ont pas, et Gluetun en tire un au hasard dans `SERVER_CITIES` à chaque démarrage. Sans IPv6 de bout en
  bout, la sonde échoue et l'IPv6 reste `unreachable` pour ce VPN.
- **Bascule indépendante par famille** : `VPN_IPS6` liste, dans le même ordre que `VPN_IPS`, l'adresse IPv6 de
  chaque Gluetun (les premiers seulement si les derniers n'en ont pas). Chaque famille a ses sondes
  (`PROBE_URLS6`), son compteur `FAIL_THRESHOLD` / `RISE_THRESHOLD` et son fichier d'état :
  `/run/gateway/active` (IPv4) et `/run/gateway/active6`. Un VPN dont l'IPv6 tombe garde l'IPv4.
- **Découverte de voisins** : `post-rules-N.txt` ouvre `neighbour-solicitation` et `neighbour-advertisement` sur
  `eth+`, sinon le pare-feu IPv6 de Gluetun ignore la sollicitation multicast et le gateway ne résout jamais
  l'adresse du Gluetun à froid.
- **Pas d'annonces de routeur (RA)** : `accept_ra=0` sur `eth0` du gateway (`driver_opts` du réseau). Un RA émis par
  un autre conteneur du réseau ajouterait sinon une route par défaut que nftables bloquerait : pas de fuite, mais plus
  de sortie IPv6, car `ip -6 route replace default` ne remplace pas une route de métrique plus basse.
- **Gluetun refuse une adresse WireGuard IPv6 si aucun de ses réseaux Docker n'a `enable_ipv6`** (`interface address
  is IPv6 but IPv6 is not supported`) : `vpn-gateway` suffit, `frontend` reste en IPv4.
- **Pas d'`ALLOW_IN` / `ALLOW_OUT` IPv6** : aucune entrée ni appel LAN en IPv6 n'est prévu.

### 4.6 Couches fail-closed, de l'app vers Internet

1. L'app n'a aucune capacité (`cap_drop: [ALL]`, comme les `wgentryN`) : ni `NET_ADMIN` (routes, firewall) ni
   `NET_RAW` (socket brut qui contournerait nftables, usurpation ARP sur `vpn-gateway`).
2. Route par défaut du gateway : un Gluetun ou `unreachable`.
3. nftables du gateway : sortie Internet seulement via un next-hop Gluetun, en IPv4 comme en IPv6 ; DNS
   seulement vers les Gluetun.
4. `vpn-gateway` est `internal` : même une route vers `172.30.20.1` (ou `fd30:20::1`) ne mènerait nulle part.
5. Gluetun : forward seulement vers `tun0`, politique DROP sinon.

#### Limite connue : le démarrage d'un Gluetun

Mesurée le 2026-10-14 (capture sur l'hôte, flot de 40 SYN/s sous l'UID de sonde, 14 essais) :

| Événement sur un Gluetun | Paquets sortis par l'interface physique de l'hôte |
|---|---|
| démarrage à froid (×5) | 4 à 46 paquets IPv4, de 0,17 s à 0,31 s après `docker start` |
| `docker restart` (×3) | 8 à 9 paquets IPv4, ≈ 0,1 s |
| `docker stop` (×3), `docker kill` (×3) | aucun |
| IPv6, tous événements | aucun |

Le Gluetun a `ip_forward=1` dès la création du conteneur, mais ses règles `iptables` ne sont posées qu'une fraction de
seconde plus tard : les paquets du gateway sortent alors par sa route par défaut côté réseau non interne (`frontend`),
avec leur adresse source privée. Seules des **sondes** en sont victimes (le trafic de l'application n'est routé qu'après
`RISE_THRESHOLD` sondes réussies consécutives, soit quelques secondes de Gluetun en fonctionnement). Le gateway ne
cause rien : sans Gluetun, rien ne sort (`unreachable`, réseau `internal`).

- **IPv6 n'est pas touchée parce que `frontend` n'a pas `enable_ipv6`** : le Gluetun n'a alors aucune route IPv6 hors de
  `tun0`. Ne jamais activer l'IPv6 sur un réseau non interne d'un Gluetun sans refaire cette mesure.
- **Fermeture côté hôte (éprouvée IPv4)** : une règle `DOCKER-USER` qui jette tout paquet issu du réseau `vpn-gateway`
  sortant par un autre bridge. Essai du 2026-10-14 : 0 paquet sorti sur 8 essais (5 démarrages, 3 redémarrages), contre
  5 à 50 paquets sans la règle dans les 2 essais témoins ; 40 paquets jetés au compteur ; les Gluetun ne sont pas
  touchés, leur trafic légitime ne traverse jamais ce chemin. La jumelle IPv6 (`ip6tables`, préfixe ULA) est posée
  par le même script, et a été éprouvée sur un hôte réel le 2026-11-19 (pose, compteur de `DOCKER-USER` et retrait par `ip6tables`) ; la fermeture de la fuite au démarrage d'un Gluetun n'a pas été mesurée en IPv6, faute de fuite v6 à fermer.

  ```sh
  iptables -I DOCKER-USER -s 172.30.0.0/16 ! -o vpngw+ -j DROP
  ```

  La forme générique ci-dessus (plage commune, bridge `vpngw+`) a aussi été éprouvée le 2026-10-14, sur une plage de
  test : 0 paquet sorti sur 8 essais, 6 et 49 paquets sans la règle, 44 jetés au compteur. ⚠️ Poser cette règle avec une
  plage qui contient des piles existantes avant de leur avoir donné un bridge `vpngw-…` risque de couper leur trafic
  interne, puisque `br_netfilter` fait traverser `DOCKER-USER` au trafic d'un bridge vers lui-même (non mesuré). Une seule règle suffit pour plusieurs piles si chaque réseau `vpn-gateway` tient dans la plage `172.30.0.0/16` (et
  rien d'autre) et déclare `com.docker.network.bridge.name: vpngw-<pile>`. `DOCKER-USER` est vidée au redémarrage du
  démon Docker : à poser par un service systemd ou la configuration nftables de l'hôte.

#### Service hôte : la règle `DOCKER-USER`

`host/vpngw-firewall.sh` pose sur l'hôte la règle de fermeture ci-dessus, et `host/vpngw-firewall.service` la repose à chaque
démarrage de Docker (`DOCKER-USER` est vidée avec le démon). Elle ne porte que sur le sous-réseau `vpn-gateway` : tout paquet
de cette source qui sort par un autre pont que `vpngw-egress` est jeté. `frontend` et les autres réseaux de la plage ne sont pas
touchés, ce qui la distingue de la forme `-s 172.30.0.0/16 ! -o vpngw+` mesurée plus haut, qui couperait aussi la sortie de
Caddy. Le compose de l'exemple nomme le pont (`com.docker.network.bridge.name: vpngw-egress`).

```sh
sudo install -m 755 host/vpngw-firewall.sh /usr/local/sbin/vpngw-firewall.sh
sudo install -d /etc/gluetun-egress
sudo cp host/vpngw.conf.example /etc/gluetun-egress/vpngw.conf    # une ligne « sous-réseau pont » par pile et par famille
sudo cp host/vpngw-firewall.service /etc/systemd/system/
sudo systemctl enable --now vpngw-firewall
sudo iptables -vnL DOCKER-USER                                    # la règle et son compteur
```

`vpngw-firewall.sh status` dit si chaque règle est posée, `down` les retire. Pour vérifier la fermeture : `docker restart` d'un
Gluetun, puis relire le compteur de la règle (un compteur qui monte = des paquets qui auraient fui). Essai du 2026-11-19 sur une
pile à deux Gluetun (démarrage à froid, puis trois `docker restart` de `gluetun1`) : 1 paquet jeté, pont `vpngw-egress` créé, sortie
de l'application par le VPN 1 inchangée ; pas de témoin sans règle. Un sous-réseau IPv6 de la configuration (`fd30:20::/64`
dans l'exemple) passe par `ip6tables` avec la même règle ; elle exige la chaîne `DOCKER-USER` d'`ip6tables`, que Docker crée avec son
`ip6tables` actif, et le service échoue bruyamment si elle manque (retirer alors la ligne IPv6 de la configuration). Test sans droit
root : `sh host/tests/firewall/run.sh`.

### 4.7 Entrée par tunnels WireGuard

- Chaque `wgentryN` (wireproxy) partage le namespace de `gluetunN` : son UDP vers le relais sort **par le VPN N**.
  Le relais voit trois pairs d'adresses différentes, et l'entrée suit la même panne que la sortie : VPN mort, tunnel mort.
- Ni capacité Linux ni `/dev/net/tun` : wireproxy embarque WireGuard en espace utilisateur, ce qui garde
  `cap_drop: [ALL]`. Contrepartie : le débit est borné par le CPU de wireproxy, pas par le noyau (§9).
- `PersistentKeepalive = 25` maintient le NAT du VPN ; la poignée de main se renouvelle toutes les 2 minutes
  (`wg show wg0 latest-handshakes` sur le relais).
- **Sélection du tunnel** : le relais n'équilibre pas, il prend le premier upstream dont la sonde `/healthz` répond
  (`lb_policy first`). Pour répartir entre les VPN en vie : `lb_policy round_robin`.
- Une panne de VPN est vue par la sonde du relais en `health_interval` (5 s), sans attendre le failover sortant du
  gateway.
- Caddy ne croit `X-Forwarded-For` que des trois Gluetun (`172.30.10.11-13`, `trusted_proxies` du `Caddyfile`) : c'est
  l'adresse de connexion de wireproxy. L'en-tête vient du relais, qui écrase celui du client : le relais fait donc
  partie de la frontière de confiance.
- L'application reçoit `X-Forwarded-For: <client>, <Gluetun>` : le premier élément est l'adresse du client.
- **Essai du 2026-11-19** (deux Gluetun réels, relais dans un conteneur sur `frontend` : le trajet par Internet n'est donc pas
  couvert) : poignée de main sur les deux tunnels ; 20 Mo transférés exacts par le tunnel 1, sans souci de MTU ; un
  `X-Forwarded-For` forgé par le client est écrasé par le relais ; basculement sur le tunnel 2 en 5 s à l'arrêt du Gluetun 1 (la
  requête en cours à ce moment attend son timeout) ; retour sur le tunnel 1 3 s après `docker compose restart wgentry1`. Après un
  redémarrage du relais, les tunnels reprennent en une minute environ : le relais n'a pas d'`Endpoint`, ce sont les pairs qui
  relancent la poignée de main.

---

### 4.8 Qualité du serveur VPN (`gateway/vpn-check.sh`)

Gluetun tire un serveur au hasard dans son filtre (`SERVER_CITIES`…) ; sa sonde native ne dit que « une
connexion sort ». `vpn-check.sh` remplace la sonde Docker de chaque Gluetun : il appelle la sonde native, puis,
**une fois par IP publique**, mesure la latence (`VPN_CHECK_LATENCY_URL`), joint chaque `VPN_CHECK_URLS`
et télécharge `VPN_CHECK_SPEED_URL` (`VPN_CHECK_BYTES` en est la taille). Un serveur recalé est remplacé par
`PUT /v1/vpn/status` (`stopped` puis `running` : Gluetun en retire un), au plus `VPN_CHECK_MAX_REROLLS` fois ;
au-delà, le serveur est gardé un contrôle de plus, le conteneur reste *unhealthy*, puis un nouveau cycle de tirages repart. Les verdicts sont dans `docker logs`
(`[vpn-check]`).

| Variable | Défaut |
|---|---|
| `VPN_CHECK_MIN_MBPS` | `20` |
| `VPN_CHECK_MAX_LATENCY_MS` | `300` (requête HTTPS complète, poignée TLS comprise) |
| `VPN_CHECK_LATENCY_URL` | `https://1.1.1.1/cdn-cgi/trace` (cible de la mesure de latence et de l'attente d'internet avant le téléchargement d'Ookla) |
| `VPN_CHECK_URLS` | `https://www.google.com/generate_204 https://www.wikipedia.org/` |
| `VPN_CHECK_SPEED_URL` | `https://proof.ovh.net/files/10Mb.dat` (fichier de taille fixe) |
| `VPN_CHECK_BYTES` | `10485760` (taille exacte du fichier ci-dessus, base du calcul du débit) |
| `VPN_CHECK_MAX_REROLLS` | `8` |
| `VPN_CHECK_REQUIRE_IPV6` | `0` (`1` : un serveur dont `tun0` n'a pas d'adresse IPv6 globale, par exemple après un MTU découvert sous 1280, est recalé ; à poser sur les Gluetun dont le fournisseur donne une IPv6) |
| `VPN_CHECK_BAD_TTL_SECONDS` | `86400` (une IP recalée l'est d'office, sans test, pendant ce délai ; `0` : aucune mémoire) |
| `VPN_CHECK_ENGINE` | `http` (défaut : téléchargement de `VPN_CHECK_BYTES`, aucun binaire tiers) ou `ookla` (speedtest d'Ookla : latence et débit, voir ci-dessous) |
| `VPN_CHECK_OOKLA_ACCEPT_LICENSE` | `yes`. `no` : la licence d'Ookla n'est pas acceptée et le moteur `ookla` se replie sur `http` (une ligne dans les logs) |
| `VPN_CHECK_OOKLA_TIMEOUT` | `50` (secondes, sous le `timeout` du healthcheck) |
| `VPN_CHECK_OOKLA_VERSION` | `1.2.0` (version attendue du CLI) |
| `VPN_CHECK_OOKLA_URL` | `https://install.speedtest.net/app/cli/ookla-speedtest-<version>-linux-x86_64.tgz` (HTTPS obligatoire) |
| `VPN_CHECK_OOKLA_SHA256` | somme SHA-256 de l'archive, livrée pour la `1.2.0` ; **obligatoire pour toute autre version**, sans quoi le binaire est refusé |
| `VPN_CHECK_OOKLA_RETRY_SECONDS` | `3600` (délai avant de retenter un téléchargement ou un contrôle en échec) |
| `VPN_CHECK_RECHECK_SECONDS` | `3600` (`0` : jamais, un serveur validé n'est pas retesté tant que l'IP ne change pas) |
| `VPN_CHECK_FAST_START` | `1` : le Gluetun est déclaré sain dès que sa sonde native passe, sans attendre le speedtest ; la mesure et les remplacements de serveur se font ensuite en tâche de fond (un remplacement coupe brièvement le tunnel, les dépendants sont relancés). `0` : un `depends_on: service_healthy` n'aboutit qu'avec un serveur validé |
| `VPN_CHECK_NAME` | `vpn1`, `vpn2`… : le nom du tunnel côté gateway (rang dans `VPN_IPS`), requis pour le retest |

Câblage (pas à pas au §3.2.1) : `vpn-check.sh` est livré **dans l'image du gateway**, qui le dépose à chaque
démarrage dans le volume `gateway-state` ; les Gluetun le montent en lecture seule, avec
`HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000` et une clé d'API (`HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE`, §3.2.1) : le
serveur de contrôle n'écoute que sur la boucle locale et refuse toute requête sans la clé. `start_period: 4m` laisse
le temps des remplacements : un `depends_on: service_healthy` n'aboutit qu'avec un serveur validé.
⚠️ `SERVER_NAMES` réduit à un seul serveur rend le remplacement inopérant.

**Moteur `ookla`.** Le CLI d'Ookla n'est **pas** dans l'image (binaire non redistribuable) : `vpn-check.sh` le télécharge une fois, par le tunnel qui vient d'être validé, dans `/tmp` du Gluetun (`VPN_CHECK_OOKLA_URL`, version `VPN_CHECK_OOKLA_VERSION`). Le téléchargement attend que `VPN_CHECK_LATENCY_URL` réponde par le tunnel (un tunnel qui vient de monter n'a pas toujours de route ni de DNS : sans internet, rien n'est téléchargé et le prochain contrôle réessaie, sans le délai d'une heure), passe en HTTPS (certificats vérifiés, aucune redirection suivie) et le fichier est refusé si sa somme SHA-256 diffère de `VPN_CHECK_OOKLA_SHA256` (livrée pour la `1.2.0` ; Ookla n'en publie pas : elle vient du paquet AUR `ookla-speedtest-bin` et d'un téléchargement recoupé, à refaire de la même façon pour une autre version), ou s'il échoue à l'un de ces contrôles : taille de 0,5 à 30 Mo, archive contenant `speedtest` sans chemin absolu ni `..`, en-tête ELF x86_64, `speedtest --version` annonçant la version attendue. Il s'exécute en root dans le Gluetun : l'URL de téléchargement est donc une frontière de confiance. Si le téléchargement ou un contrôle échoue, la mesure retombe sur le moteur `http` (une ligne dans les logs) et le téléchargement est retenté après `VPN_CHECK_OOKLA_RETRY_SECONDS`. Le Gluetun perd son binaire à sa recréation : il est alors retéléchargé. Ce n'est pas le moteur par défaut (`VPN_CHECK_ENGINE=ookla` l'active) : la latence et le débit viennent de son test
(la joignabilité de `VPN_CHECK_URLS` reste testée), avec `VPN_CHECK_OOKLA_ACCEPT_LICENSE=yes` par défaut. Trois points à savoir avant de l'activer :
- **Licence :** le CLI se déclare réservé à un usage personnel et non commercial, sur un ordinateur personnel, et
  n'est pas redistribuable. Le script passe `--accept-license` tant que `VPN_CHECK_OOKLA_ACCEPT_LICENSE` vaut `yes`
  (défaut) : mettre `no` pour ne pas l'accepter.
- **Volume :** le test n'a pas d'option pour borner les octets. Mesuré à 7 Go en 7,5 s sur une ligne très rapide ; sur un
  tunnel à 100 Mbit/s, de l'ordre de la centaine de Mo par test et par tunnel, en téléchargement et en envoi. Avec le
  retest, choisir `VPN_CHECK_RECHECK_SECONDS` en heures, pas en minutes.
- **Durée :** 15 à 30 s par test, le tunnel est saturé pendant ce temps. À la connexion, jusqu'à
  `VPN_CHECK_MAX_REROLLS` tests peuvent s'enchaîner : `start_period` peut devoir dépasser 4 minutes.
Architecture : x86_64 seulement, sinon la mesure retombe sur `http`.

**Retest périodique.** Avec `VPN_CHECK_RECHECK_SECONDS` > 0, un serveur validé est retesté (latence, débit) quand sa
validation a plus de N secondes ; un serveur devenu lent est remplacé comme à la connexion, et le gateway retire le
tunnel de la route pendant le remplacement. **Garde-fou :** le gateway publie les tunnels en vie dans
`/run/gateway/up` (volume `gateway-state`, monté en lecture seule dans chaque Gluetun). `vpn-check.sh` ne retest un
tunnel que si un *autre* tunnel est en vie : le dernier est gardé, même lent, plutôt que de couper la sortie. Sans
fichier lisible ou sans `VPN_CHECK_NAME`, pas de retest. Le coût est d'environ `VPN_CHECK_BYTES` par tunnel et par
période. Gluetun n'a pas de liste d'exclusion : `vpn-check.sh` mémorise lui-même les IP recalées (`/tmp/vpn-check.bad`, perdu à la
recréation du conteneur) et les recale d'office pendant `VPN_CHECK_BAD_TTL_SECONDS`, ce qui évite de reprendre un serveur
qui vient d'échouer ; l'expiration empêche qu'un filtre à peu de serveurs soit entièrement exclu.

**État des tunnels.** Le gateway écrit `/run/gateway/tunnels.json` à chaque cycle (`{"written_at", "tunnels": [{"name", "up", "public_ip", "latency_ms", "down_mbps", "up_mbps", "measured_at"}]}`, les cinq derniers champs à `null` sans mesure). `vpn-check.sh` dépose la dernière mesure d'un tunnel validé dans `/gateway-measure/measure` (`latence_ms débit_mbit date ip_publique débit_montant_mbit`, ce dernier seulement avec le moteur Ookla), un volume propre à chaque Gluetun (`measure-vpn1`, `measure-vpn2`…) : c'est le seul endroit où un Gluetun écrit, `gateway-state` reste en lecture seule chez lui. Le gateway monte ces volumes en lecture seule sur `/run/gateway-measure/vpn1`, `vpn2`… (tout compose de production doit faire de même) et traite le fichier comme non fiable : il n'est lu que s'il est un fichier ordinaire (jamais un lien symbolique) et chaque champ est validé. L'écriture est atomique (`measure.tmp` puis `mv` dans le même dossier). Risque résiduel accepté : le contrôle `-f` / `! -L` n'est qu'une optimisation, le vrai garde-fou est la lecture bornée et chronométrée ; un remplacement par un lien symbolique après le contrôle peut faire lire au gateway (root) les 256 premiers octets d'un fichier local du gateway, mais seuls des jetons en forme de chiffres ou d'IP passent la validation, et seuls les admins les voient. À chaque changement d'adresse publique d'un Gluetun (région ou serveur changé), `vpn-check.sh` réécrit tout de suite ce fichier avec la nouvelle adresse et sans latence ni débit : la ligne montre le bon serveur avant la fin de la validation, et ses champs de mesure restent `null` jusqu'à elle. Sans ce volume, aucune mesure n'est déposée et `public_ip`, `latency_ms`, `down_mbps`, `up_mbps`, `measured_at` restent `null`. `tunnels.json` reste dans `/run/gateway` (volume `gateway-state`, écrit par le gateway seul).

## 5. Validation

**Le pare-feu seul, sans pile.** Contrôler la syntaxe de `rules.nft` avec des ensembles vides puis remplis
(c'est ce que `entrypoint.sh` fait au démarrage) :

```sh
docker build -t gluetun-egress-check gateway
docker run --rm --cap-add NET_ADMIN -e ALLOW_IN="172.30.20.10:4041" -e ALLOW_OUT="172.30.20.20:6379" \
  --entrypoint sh gluetun-egress-check -c '
    set_elements() { [ -n "$1" ] || return 0; printf "elements = { %s }" "$(echo $1 | sed "s/ /, /g; s/:/ . /g")"; }
    sed -e "s|# @ALLOW_IN@|$(set_elements "$ALLOW_IN")|" -e "s|# @ALLOW_OUT@|$(set_elements "$ALLOW_OUT")|" \
      -e "s|# @NEXTHOPS6@|elements = { fd30:20::11, fd30:20::12 }|" /etc/gateway/rules.nft > /run/rules.nft
    nft -c -D LAN=172.30.20.0/24 -D LAN6=fd30:20::/64 -D INGRESS=172.30.20.10 -D APP_PORT=8080 \
      -D NEXTHOPS="{ 172.30.20.11, 172.30.20.12 }" -f /run/rules.nft && echo ok'
```

**Contrôles statiques.** `sh tools/lint.sh` lance shellcheck, hadolint, actionlint et gitleaks (historique compris), chacun dans un
conteneur Docker ; la CI le lance avant de construire l'image.

**La pile réelle**, ci-dessous.

⚠️ Les noms de conteneurs de cette section (`vpnstack-gateway-1`, `vpnstack-gluetun1-1`, …) sont ceux du
projet compose de `example/` (`name: vpnstack`). Avec un autre nom de projet, ou la pile d'une autre
application, remplacer `vpnstack` par le sien (`docker compose ps` les liste).

Raccourci pour exécuter une commande **dans le namespace réseau de l'app** (fonctionne même si
l'image de l'app n'a pas de shell) :

```sh
A() { docker run --rm --network container:vpnstack-app-1 alpine:latest "$@"; }
```

| # | Vérification | Commande | Attendu |
|---|---|---|---|
| 1 | Interfaces visibles par l'app | `A cat /proc/net/dev \| awk 'NR>2{print $1}'` | `lo:` `eth0:` |
| 2 | Route par défaut de l'app | `A ip route` | `default via 172.30.20.11 dev eth0` |
| 3 | Routes du gateway | `docker exec vpnstack-gateway-1 ip route` | idem + `172.30.20.0/24 dev eth0` |
| 4 | Policy routing | `docker exec vpnstack-gateway-1 sh -c 'ip rule; for t in 101 102 103; do ip route show table $t; done'` | règles 1001-1003 + 1999, une route par table |
| 4b | VPN actif | `docker exec vpnstack-gateway-1 cat /run/gateway/active` | `vpn1` |
| 4c | Firewall | `docker exec vpnstack-gateway-1 nft list table inet vpngw` | set `nexthops` = `.11, .12, .13` |
| 5-6 | Forwarding Gluetun N | `docker exec vpnstack-gluetun1-1 sh -c 'iptables -vnL FORWARD; iptables -t nat -vnL POSTROUTING'` | compteurs `-o tun0` et retour non nuls |
| 7-8 | IP publique de chaque VPN | `docker exec vpnstack-gluetun1-1 wget -qO- https://api.ipify.org` (idem 2, 3) | une IP par fournisseur |
| 9 | IP publique vue par l'app | `A wget -qO- https://api.ipify.org` | = IP de gluetun1 |
| 10 | DNS de l'app | `A cat /etc/resolv.conf; A nslookup example.com` | serveur `172.30.20.11` (ou .12/.13) |
| 14 | Caddy → app | `docker exec vpnstack-caddy-1 wget -qO- http://127.0.0.1/` | réponse de l'app, `RemoteAddr: 172.30.20.10:…` |
| 15 | Relais → Caddy | sur le relais : `wg show wg0 latest-handshakes`, puis `curl -sI https://<hostname>` | poignée de main récente par pair, HTTP 200 |
| 16-17 | Sortie de chaque Gluetun d'entrée | `docker run --rm --network container:vpnstack-wgentry1-1 alpine:latest wget -qO- https://api.ipify.org` (idem 2, 3) | = IP du VPN correspondant |
| — | Quel tunnel sert le trafic | sur le relais : `wg show wg0 transfer` | le compteur qui monte |

---

## 6. Tests de failover, failback et anti-fuite

Suivre l'état pendant les tests :

```sh
watch -n2 'docker exec vpnstack-gateway-1 sh -c "cat /run/gateway/active; ip route show default"'
docker compose logs -f gateway | grep --line-buffered 'sortie active'
```

**Simuler une panne : `docker stop vpnstack-gluetunN-1`**. Le `wgentryN` associé perd son
réseau avec lui (le relais bascule sur un autre tunnel) ; il reste affiché `Up` mais devra être
redémarré au retour (voir Failback). Ne pas injecter de règle `iptables -I OUTPUT … ! -d …`
dans un Gluetun : Gluetun n'arrive plus à relire sa propre table tant qu'elle est présente
(`ERROR [firewall] cannot remove outdated VPN interface rule`).

### Failover en cascade

```sh
docker stop vpnstack-gluetun1-1   # attendu : vpn2, A wget … → IP Proton
docker stop vpnstack-gluetun2-1   # attendu : vpn3, A wget … → IP du profil custom
docker stop vpnstack-gluetun3-1   # attendu : none
```

### Fail-closed (aucun VPN)

```sh
A wget -T5 -qO- https://9.9.9.9/        # Host is unreachable
A nslookup example.com                   # échec
A nslookup example.com 8.8.8.8           # Operation not permitted
A nslookup example.com 127.0.0.11        # Operation not permitted
A wget -T3 -qO- http://172.30.20.1/      # timeout (pont Docker du host)
A ip route replace default via 172.30.20.1          # Operation not permitted (pas de NET_ADMIN)
docker exec vpnstack-gateway-1 ip route replace default via 172.30.20.1
A wget -T3 -qO- https://9.9.9.9/        # bloqué par nftables ; la route est rétablie au cycle suivant
```

Ces refus sont aussi valables quand un VPN est actif (DNS externe, `127.0.0.11`, pont host).

### Failback

```sh
docker compose up -d gluetun3 && docker compose restart wgentry3   # attendu : vpn3
docker compose up -d gluetun1 && docker compose restart wgentry1   # attendu : retour sur vpn1
docker compose up -d gluetun2 && docker compose restart wgentry2
```

Le `restart` est indispensable : un `wgentryN` dont le Gluetun a été arrêté reste accroché à
l'ancien namespace, sans aucune interface (`Network unreachable`), et `docker compose up -d` ne le
recrée pas. Vérifier sur le relais : `wg show wg0 latest-handshakes` (poignée de main de moins d'une minute).

### Délais mesurés (réglages par défaut, vrais VPN)

| Transition | Délai |
|---|---|
| Panne d'un VPN → VPN suivant | 38-43 s |
| Dernier VPN en panne → `none` | 43 s |
| Retour d'un VPN prioritaire | 9-39 s (plus long si Gluetun a dû se reconnecter à un nouveau serveur) |

Délai de détection d'un tunnel lent ou muet (Gluetun joignable) ≈ `FAIL_THRESHOLD × (PROBE_INTERVAL + nombre de PROBE_URLS × PROBE_TIMEOUT)`.
Un conteneur arrêté ou un réseau coupé ne répond pas au ping : `FAIL_THRESHOLD × (PROBE_INTERVAL + 2 s)`.
Pour basculer plus vite : baisser `FAIL_THRESHOLD` ou `PROBE_TIMEOUT`, au prix de bascules
intempestives sur un VPN lent.

---

## 7. Exploitation

### Changer de pays ou de serveur

Modifier `SERVER_COUNTRIES` / `SERVER_CITIES` dans `.env.vpnN`, puis `docker compose up -d` : Compose
recrée `gluetunN` et son `wgentryN`. Le gateway bascule sur un autre VPN pendant la
reconnexion puis revient.

**À chaud, par l'API de Gluetun** (sans recréer le conteneur) : `PUT /v1/vpn/settings` avec les réglages complets et la clé d'API
dans `X-API-Key` (`VPN_CHECK_APIKEY` du `.env`). Le Gluetun se reconnecte au nouveau filtre en quelques secondes (essai : France,
Allemagne, puis France/Marseille, 8 s chacun) ; le gateway bascule sur un autre VPN pendant ce temps. Il faut `jq` sur l'hôte.

```sh
set -a; . ./.env; set +a                       # charge VPN_CHECK_APIKEY
C=vpnstack-gluetun1-1
api() { docker exec "$C" wget -qO- --header="X-API-Key: $VPN_CHECK_APIKEY" "$@"; }
corps=$(api http://127.0.0.1:8000/v1/vpn/settings \
  | jq -c '.provider.server_selection.countries=["germany"] | .provider.server_selection.cities=null')
api --header='Content-Type: application/json' --method=PUT --body-data="$corps" http://127.0.0.1:8000/v1/vpn/settings
api http://127.0.0.1:8000/v1/publicip/ip                      # pays et ville effectifs
```

- Noms en anglais et en minuscules ; remettre `cities` à `null` en changeant de pays (les filtres se cumulent). Pour une ville :
  `.provider.server_selection.cities=["marseille"]`.
- **Non persistant** : à la recréation du conteneur, `.env.vpnN` reprend la main. Reporter le choix dans le fichier.
- `--body-data` et non `--body-file=/dev/stdin` : ce dernier est ignoré sans erreur.
- Le `GET` renvoie les réglages **avec la clé privée WireGuard** : ne pas le journaliser. La route n'est pas dans la documentation de
  Gluetun (essai du 2026-11-19 sur `latest`) : la rejouer après une montée de version.

### Ajouter un 4ᵉ VPN

1. `.env.vpn4` (droits 600).
2. `gluetun/post-rules-4.txt` : copie de `post-rules-3.txt` avec `172.30.20.13` → `172.30.20.14` et `fd30:20::13` → `fd30:20::14`.
3. Dans `docker-compose.yml` : services `gluetun4` (`.10.14` / `.20.14`) et `wgentry4` sur le
   modèle de `gluetun3`/`wgentry3` ; ajouter `172.30.10.14` à
   `trusted_proxies` du `Caddyfile` ; ajouter `172.30.20.14` à `VPN_IPS` du gateway
   (l'ordre = la priorité).
4. `example/wgentry/wg4.conf` (copie de `wg3.conf.example`, adresse `10.99.4.2/32`) et un `[Peer]` de plus dans `wg0.conf` du relais, avec son upstream `10.99.4.2:80` dans le `Caddyfile` du relais.
5. `docker compose up -d --build`.

Rappel : le 4ᵉ `nameserver` sera ignoré par les resolvers (limite de 3).

### Changer le plan d'adressage

`tools/set-addressing.sh <préfixe frontend> <préfixe vpn-gateway> [préfixe ULA|-] [nom de pile]` réécrit d'un coup les quatre endroits du plan
(compose, gateway, post-rules, Caddyfile), ainsi que le modèle de `.env`, les modèles `wgentry`, la CI et `host/`. Les
sous-réseaux restent des `/24` (IPv4) et un `/64` (ULA) ; seuls les trois premiers octets changent, les hôtes gardent leur rang
(`.2` gateway, `.10` Caddy, `.11` et suivants les Gluetun).

```sh
tools/set-addressing.sh 10.50.1 10.50.2 fd50:2:1 blog
```

Le nom de pile (9 caractères, `a-z` et `0-9`) devient le nom du projet Compose, donc le préfixe des conteneurs (`blog-gateway-1`),
et le pont `vpngw-blog`. Sans lui, la pile garde `vpnstack` et `vpngw-egress`.

#### Plusieurs piles sur un même hôte

Un dépôt (une copie) par pile, chacune réglée par `tools/set-addressing.sh` avec **ses propres plages et son propre nom** :
deux piles ne peuvent partager ni un sous-réseau, ni un nom de projet, ni un pont. Le script refuse une plage déjà prise par un
réseau Docker (comparaison exacte des `/24` ; une plage plus large qui recouvre la vôtre n'est pas détectée).
Rien d'autre ne se partage : les tables `nftables` du gateway vivent dans le namespace de chaque pile, aucun port n'est publié sur
l'hôte, les volumes sont propres au projet. Côté hôte, une seule règle par pile dans `/etc/gluetun-egress/vpngw.conf`, une ligne
chacune. Deux limites : **une clé WireGuard ne sert qu'une pile à la fois** (un fournisseur la refuse sur deux appareils), et
chaque pile qui lance `vpn-check.sh` avec le moteur `ookla` sature ses tunnels pendant le test : décaler leur
`VPN_CHECK_RECHECK_SECONDS`.

Essai du 2026-11-19, deux piles en parallèle (`stka` en `10.61.x`, `stkb` en `10.62.x`, une clé Proton chacune) : sorties par
des IP distinctes, ponts `vpngw-stka` et `vpngw-stkb` avec une règle hôte chacun, aucun accès d'une pile à l'autre (application ou
Gluetun vers le Caddy ou le gateway de l'autre), redémarrer `gluetun1` et le gateway de A laisse B inchangé (même IP de sortie), et
`set-addressing.sh` refuse pour B la plage de A, déjà prise par un réseau Docker. Les deux piles tournaient sans `wgentry`.

- Préfixes privés seulement (10/8, 172.16/12, 192.168/16, ULA `fc00::/7`), `frontend` différent de `vpn-gateway`, sans
  recouvrement avec un réseau Docker existant (`docker network ls`, puis `docker network inspect`).
- Sans recouvrement avec les autres piles de l'hôte : le script le contrôle avec `docker network ls`.
- Le README n'est pas réécrit : il décrit les valeurs d'origine. `tools/addressing.env` garde les valeurs courantes ; relancer
  avec les mêmes valeurs ne change rien.
- `host/vpngw.conf.example` suit le sous-réseau `vpn-gateway` ; reporter la ligne dans `/etc/gluetun-egress/vpngw.conf` et
  relancer `systemctl restart vpngw-firewall` (§4.6).
- Après changement : `docker compose config -q` dans `example/`, puis `sh tools/tests/addressing/run.sh`.

### Redémarrages

- `docker compose restart gateway` ou `docker compose up -d` : Compose redémarre aussi l'app
  (`depends_on.restart: true`). Même chose pour `gluetunN` → `wgentryN`.
- **Règle générale : un conteneur en `network_mode: service:X` est orphelin si X redémarre hors de
  Compose** (`docker stop`/`start`, `docker restart`, crash + politique `restart`). Il reste `Up`
  mais sans réseau. Les reconnexions VPN internes à Gluetun ne sont pas concernées (le conteneur ne
  redémarre pas). Réparation : `docker compose restart <dépendant>`.
- **Relance automatique des dépendants** : si le gateway a `RESTART_DEPENDENTS_<n>` (noms de conteneurs) et le
  socket Docker monté, il relance ces conteneurs quand le Gluetun n repasse *up* après avoir été *down*
  (jamais au premier démarrage). Le gateway ne monte pas le socket Docker : il parle à un `socket-proxy` (`wollomatic/socket-proxy`) qui n'autorise que `POST …/restart` sur les conteneurs `wgentryN` (regex `allowPOST` du compose, à élargir pour un autre conteneur à relancer), par un socket Unix dans un volume que seul le gateway monte (l'application partage son réseau mais pas son système de fichiers). Le proxy monte, lui, le vrai socket en lecture seule, sans capacité, système de fichiers en lecture seule : un conteneur de plus à surveiller, mais une surface bien plus petite que le gateway entier. La surveillance du port redirigé (`PORT_FORWARD_<n>`) a besoin de plus : `GET …/json` et `GET …/archive` sur le Gluetun, et `POST …/restart` sur lui ; l'exemple ne les ouvre pas. Pour les ouvrir, ajouter `gluetun` à la regex `allowPOST` (`vpnstack-(gluetun|wgentry)[0-9]+-1`) et une ligne `-allowGET=^(/v[0-9.]+)?/containers/vpnstack-gluetun[0-9]+-1/(json|archive)$$` (`$$` dans un compose). Limites de ces deux lignes : `json` renvoie l'environnement du conteneur, clés WireGuard et clé d'API du Gluetun comprises, et `archive` ne filtre pas le chemin lu : un proxy détourné lirait ces secrets. Un Gluetun relancé en moins de `FAIL_THRESHOLD × PROBE_INTERVAL`
  secondes n'est pas vu comme *down* : sa relance n'est alors pas détectée.
- **Surveillance du port redirigé** : avec `PORT_FORWARD_<n>` (nom du conteneur du Gluetun n) et le socket Docker monté,
  le gateway lance `watch-port-forward.sh` pour ce Gluetun : si `/gluetun/forwarded_port` manque `PF_MISS_LIMIT` contrôles
  de suite (défaut 6, un toutes les `PF_CHECK_EVERY` secondes, défaut 30), le Gluetun est relancé (il change de serveur, et
  la redirection revient presque toujours : sa demande NAT-PMP peut expirer au démarrage sans jamais être renouvelée), puis,
  `PF_DEPENDENTS_DELAY` secondes après (défaut 5), les conteneurs de `RESTART_DEPENDENTS_<n>`. Cette relance-là est faite par
  le script lui-même : un redémarrage rapide n'est pas vu comme *down* par le gateway. Un conteneur arrêté n'est jamais relancé.
  `PORT_FORWARD_FILE` change le fichier lu. Test, sans conteneur ni vrai socket : `sh gateway/tests/watch-port-forward/run.sh`
  (faux démon Docker en Python, `python3` requis ; environ 25 s).
- **Si le gateway redémarre hors de Compose** (politique `restart` du conteneur, `docker restart`),
  l'app reste accrochée à l'ancien namespace, sans aucune interface : **elle n'a plus de réseau du
  tout** (fail-closed, pas de fuite) jusqu'à `docker compose up -d --force-recreate app`.

### Logs

```sh
docker compose logs -f gateway          # bascules et diagnostics de sonde
docker compose logs -f gluetun1         # connexion VPN, IP publique, healthcheck Gluetun
docker compose logs -f wgentry1         # tunnel WireGuard d'entrée
```

### Secrets

`.env` et `.env.vpn*` contiennent les clés privées WireGuard (`wgentry/wgN.conf` aussi) : droits 600,
jamais versionnés (voir `.gitignore`). Une clé exposée se régénère chez le fournisseur (NordVPN,
Proton, …) ; la clé d'un tunnel d'entrée se régénère avec `wg genkey`, puis se remplace dans `wgN.conf` et sur le relais.

---

## 8. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| Le gateway reste en `none` alors que les Gluetun sont *healthy* | `rp_filter` réactivé | Vérifier `docker exec vpnstack-gateway-1 sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth0.rp_filter` → 0 et 0 |
| `gluetunN` *unhealthy*, logs `lookup … i/o timeout` en boucle | Handshake WireGuard qui échoue sur ce serveur | Normal au démarrage (Gluetun change de serveur). Si ça persiste : clé invalide (NordVPN : clé NordLynx, pas le token), ou endpoint `custom` qui a changé d'IP (`getent ahostsv4 <nom>` et mettre à jour `WIREGUARD_ENDPOINT_IP`) |
| `gluetunN` refuse de démarrer après une modif de `post-rules.txt` | Une ligne invalide annule toutes les post-rules et fait échouer le firewall | `docker compose logs gluetunN \| grep -i 'post firewall'` ; si c'est `TCPMSS`, le module noyau manque : supprimer les deux lignes `mangle` |
| Réponses HTTP 502 intermittentes sur le hostname public | Le relais n'a plus de tunnel en vie, ou le Gluetun a changé d'IP et la poignée de main n'est pas refaite | `wg show wg0 latest-handshakes` sur le relais ; `docker compose restart wgentryN` |
| HTTP 502 ou 504 sous forte charge | wireproxy (WireGuard en espace utilisateur) ou le relais sature ; l'origine n'est pas en cause | Voir §9 |
| L'app n'a plus aucun réseau | Le gateway a redémarré hors Compose | `docker compose up -d --force-recreate app` |
| Un tunnel d'entrée ne se reconnecte pas, `Network unreachable` dans son namespace | Son Gluetun a redémarré hors Compose | `docker compose restart wgentryN` |
| Gluetun refuse un pays ou une ville | Nom inconnu de Gluetun pour ce fournisseur, ou filtres pays + ville incompatibles | Un seul type de filtre, noms en anglais (`United Kingdom`, `Netherlands`) |
| `interface specific sysctl setting … must be supplied using driver option` | Sysctl `net.ipv4.conf.eth0.*` mis dans `sysctls:` | Le passer par `driver_opts: com.docker.network.endpoint.sysctls` (déjà fait pour `rp_filter`) |

---

## 9. Performances

Aucune mesure publiée pour l'entrée par tunnels WireGuard. Le débit dépend du CPU de `wgentryN` (WireGuard en espace
utilisateur ; un seul tunnel porte le trafic en `lb_policy first`), du débit du VPN N et de la bande passante du
relais. Pour mesurer : `oha` depuis une machine qui n'est ni le relais ni la pile, en regardant `docker stats wgentry1`,
le premier à saturer. Ajouter des tunnels n'ajoute de la capacité qu'avec `lb_policy round_robin`.

---

## 10. Choix techniques et limites

- **Pas de proxy applicatif** (HTTP, SOCKS, Shadowsocks) : le routage est transparent au niveau IP.
- **Caddy n'est pas derrière les VPN** et ne sert jamais au failover sortant.
- **Sondes par UID + `ip rule uidrange`** plutôt que par marque de paquet : aucune règle nftables de
  marquage, chaque VPN est testé indépendamment de la route active. Les UID 64101-641NN ne doivent
  pas être utilisés par l'application (le noyau voit les UID réels).
- **Une sonde réussie = tunnel fonctionnel ET Internet accessible** : ces deux niveaux ne sont pas
  distinguables de l'extérieur ; le `ping` du Gluetun distingue seulement « Gluetun joignable ».
- **Pas de `conntrack`** : le gateway ne fait pas de NAT, rien à purger lors d'une bascule.
- **Pas de `healthcheck.sh`** : le healthcheck Docker du gateway est une seule commande
  (`nft list table inet vpngw`).
- **Profil `custom`** : endpoint figé en IP (exigence de Gluetun), pas d'IPv6 : il n'a donc pas d'entrée dans `VPN_IPS6`.
- **Failover de 40 s environ** : compromis entre réactivité et stabilité, réglable (§6).

---

## Crédits

- [Gluetun](https://github.com/passteque/gluetun) (dépôt de l'image officielle `qmcgaw/gluetun`, licence MIT) : le client
  VPN de chaque pile (tunnels, pare-feu, DNS, serveur de contrôle). Ce dépôt n'est que le gateway de sortie fail-closed, la sonde de
  qualité et l'orchestration autour.
- wireproxy (image `ghcr.io/windtf/wireproxy`) : WireGuard en espace utilisateur pour l'entrée.
- Caddy et `wollomatic/socket-proxy` (image `wollomatic/socket-proxy`).
- Ookla Speedtest CLI : téléchargé à l'exécution, sous sa propre licence (usage personnel et non commercial).

## Licence

MIT, voir `LICENSE`.
