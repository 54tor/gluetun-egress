"""Faux démon Docker pour tester watch-port-forward.sh, sans conteneur.

Il écoute sur un socket Unix et répond aux trois appels que fait le script de surveillance :
  GET  /containers/<nom>/json     -> l'état « en marche » lu dans <dossier>/etat/running (« oui » ou « non »)
  GET  /containers/<nom>/archive  -> une archive tar avec le fichier du port, ou 404 si <dossier>/etat/port est vide ou absent
  POST /containers/<nom>/restart  -> 204, et la requête est journalisée

Chaque requête est ajoutée à <dossier>/requetes.log sous la forme « MÉTHODE CHEMIN », pour que le test les compte.
"""

import io
import json
import os
import socketserver
import sys
import tarfile
from http.server import BaseHTTPRequestHandler

chemin_du_socket = sys.argv[1]
dossier_etat = sys.argv[2]
journal_des_requetes = os.path.join(os.path.dirname(dossier_etat), "requetes.log")


def lire_etat(nom_du_fichier):
    chemin = os.path.join(dossier_etat, nom_du_fichier)
    if not os.path.exists(chemin):
        return ""
    with open(chemin, encoding="utf-8") as fichier:
        return fichier.read().strip()


def construire_archive_du_port(valeur_du_port):
    contenu = valeur_du_port.encode("utf-8")
    flux = io.BytesIO()
    with tarfile.open(fileobj=flux, mode="w") as archive:
        membre = tarfile.TarInfo(name="forwarded_port")
        membre.size = len(contenu)
        archive.addfile(membre, io.BytesIO(contenu))
    return flux.getvalue()


class GestionnaireDeRequetes(BaseHTTPRequestHandler):
    def address_string(self):
        return "unix"

    def log_message(self, *arguments):
        pass

    def journaliser(self):
        with open(journal_des_requetes, "a", encoding="utf-8") as journal:
            journal.write(f"{self.command} {self.path}\n")

    def repondre(self, code, corps=b"", type_de_contenu="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", type_de_contenu)
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        self.journaliser()
        if self.path.endswith("/json"):
            en_marche = lire_etat("running") == "oui"
            self.repondre(200, json.dumps({"State": {"Running": en_marche}}).encode())
        elif "/archive" in self.path:
            valeur_du_port = lire_etat("port")
            if valeur_du_port:
                self.repondre(200, construire_archive_du_port(valeur_du_port), "application/x-tar")
            else:
                self.repondre(404, b'{"message":"Could not find the file"}')
        else:
            self.repondre(404, b"{}")

    def do_POST(self):
        self.journaliser()
        if self.path.endswith("/restart"):
            self.repondre(204)
        else:
            self.repondre(404, b"{}")


class ServeurUnix(socketserver.UnixStreamServer):
    pass


if os.path.exists(chemin_du_socket):
    os.remove(chemin_du_socket)
ServeurUnix(chemin_du_socket, GestionnaireDeRequetes).serve_forever()
