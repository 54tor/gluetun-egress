# AGENTS.md — consignes pour les agents (Claude Code, Codex, …)

Dépôt de **gluetun-egress** : le gateway de sortie fail-closed d'une application derrière un VPN en failover,
et la pile d'exemple (Gluetun ×3, `wgentry` ×3, Caddy) qui l'accompagne. Lis `README.md` en entier avant
de toucher au pare-feu ou aux routes.

---

## Ce qui ne se négocie pas

Le gateway est une **frontière de sécurité**, pas un utilitaire. Trois invariants, à ne jamais affaiblir :

1. **Fail-closed.** Sans VPN validé, l'application n'a aucune route (`unreachable`). Le pare-feu nftables est
   chargé **avant** toute route (`entrypoint.sh`, étape 1). Un changement qui laisserait un instant de sortie
   par l'Internet de l'hôte est un bug de sécurité.
2. **Pas de fuite DNS.** `127.0.0.11` (DNS embarqué de Docker) est interdit, les ports 53/853 ne vont qu'aux
   Gluetun, le reste est jeté.
3. **Internet seulement via un Gluetun.** `rt ip nexthop @nexthops` et `rt ip6 nexthop @nexthops6` : toute autre route
   est bloquée par nftables, dans les deux familles. Une règle IPv4 sans sa jumelle IPv6 est une fuite silencieuse.

`ALLOW_IN` et `ALLOW_OUT` sont les seuls assouplissements prévus, et ce sont des **couples `ip:port`**, jamais un
sous-réseau ni un port seul. Toute demande plus large se refuse ou s'arbitre explicitement.

## Structure

| Chemin | Rôle |
|---|---|
| `gateway/` | Image du gateway : `entrypoint.sh` (firewall, routes, sondes, failover), `rules.nft`, `vpn-check.sh` (sonde de santé des Gluetun, déposée dans le volume `gateway-state`) |
| `gluetun/post-rules-N.txt` | Forwarding et NAT gateway → `tun0` dans le Gluetun N ; l'IP y est celle du plan d'adressage |
| `example/` | Une pile complète qui tourne, et qui sert de test à la main |
| `example/wgentry/`, `example/relay/` | Modèles des tunnels WireGuard d'entrée (wireproxy dans chaque Gluetun) et du relais public qui les reçoit |

Le plan d'adressage (`172.30.10.0/24` frontend, `172.30.20.0/24` vpn-gateway, `fd30:20::/64` ULA du vpn-gateway)
est écrit à **quatre endroits** : `example/docker-compose.yml`, `gateway/*`, `gluetun/post-rules-*.txt`,
`example/caddy/`. Le changer, c'est changer les quatre.

## Avant de rendre un changement

```bash
sh -n gateway/entrypoint.sh
docker build -t gluetun-egress-check gateway
(cd example && docker compose config -q)
sh gateway/tests/watch-port-forward/run.sh
```

La syntaxe de `rules.nft` se contrôle dans l'image, avec `nft -c` et des `ALLOW_IN` / `ALLOW_OUT` vides puis
remplis (commande au README §5). Les tests de failover, failback et anti-fuite sont dans le README (§6) : ils demandent une pile réelle
et ne se remplacent par rien. Un changement de `rules.nft` ou d'`entrypoint.sh` sans les avoir rejoués n'est pas
fini.

## Secrets

`.env` et `.env.vpn*` portent des clés WireGuard : jamais versionnés (`.gitignore`), jamais recopiés dans la
sortie d'un agent, jamais dans un message de commit. Les exemples ne contiennent que des noms de variables.

## Tenue du dépôt

- Commentaires : succincts, en français de France ; ils disent le *pourquoi* (une contrainte, un piège), pas le
  fonctionnement de nftables ou de Docker.
- Documentation, messages de commit et échanges en **français**, accents corrects.
- Les identifiants (variables, fichiers) restent en anglais.
- Aucun chemin absolu ni nom d'utilisateur dans un fichier suivi.
