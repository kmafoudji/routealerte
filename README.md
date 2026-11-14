# RouteAlerte — prototype

Application web qui permet de **relever** les dangers des routes nationales (dos d'âne, nids-de-poule, portions dégradées, traversées de bétail, déviations, ponts étroits, zones inondables) et d'**alerter** le conducteur avant d'y arriver.
Phase de test : tous les testeurs partagent **la même carte** grâce à une base Supabase.

## Contenu du dépôt

| Fichier | Rôle |
| --- | --- |
| `index.html` | L'application (un seul fichier) |
| `supabase/schema.sql` | Script de la base : tables, détection des doublons, sécurité, ping |
| `.github/workflows/keepalive.yml` | Ping automatique tous les 3 jours pour éviter la mise en pause de Supabase |

---

## 1. Préparer Supabase

1. **Créer le projet** sur supabase.com : nom `routealerte`, région Europe, *Enable Data API* coché, *Automatically expose new tables* décoché.
2. **Créer la base** : menu **SQL Editor** → **New query** → coller tout le contenu de `supabase/schema.sql` → **Run**.
   Le message « Success. No rows returned » indique que tout est en place. Le script peut être relancé sans risque.
3. **Activer les connexions anonymes** : **Authentication** → **Sign In / Providers** → activer **Allow anonymous sign-ins** → Save.
   Chaque téléphone est ainsi reconnu automatiquement, sans compte ni mot de passe.
4. **Récupérer les deux valeurs de connexion** (bouton **Connect** en haut, ou **Project Settings** → **API Keys** / **Data API**) :
   - l'**URL du projet** : `https://xxxxxxxx.supabase.co`
   - la **clé publishable** : `sb_publishable_…` (ou, à défaut, l'ancienne clé `anon`)

   ⚠️ N'utilisez **jamais** la clé **secret** (`sb_secret_…`) ou `service_role` dans l'appli.

## 2. Configurer l'appli

Dans `index.html`, en haut du script, remplir :

```js
const SUPABASE_URL = 'https://xxxxxxxx.supabase.co';
const SUPABASE_KEY = 'sb_publishable_xxxxxxxx';
```

La clé publishable est faite pour être publique : la sécurité est assurée par les règles de la base (lecture libre de la carte, écriture uniquement via les fonctions, suppression limitée à ses propres relevés).
Si ces deux valeurs restent vides, l'appli fonctionne en **mode local** (données sur le téléphone seulement).

## 3. Publier avec GitHub Pages

1. Créer un dépôt **public** `routealerte` sur GitHub (GitHub Pages gratuit nécessite un dépôt public).
2. Envoyer les fichiers : **Add file** → **Upload files**, en gardant l'arborescence (`supabase/`, `.github/workflows/`).
   Astuce : le dossier `.github` est caché sur certains ordinateurs ; on peut aussi créer le fichier directement sur GitHub via **Add file → Create new file** en tapant le nom `.github/workflows/keepalive.yml`.
3. **Settings** → **Pages** → *Source* : **Deploy from a branch** → branche `main`, dossier `/ (root)` → Save.
4. Après 1 à 2 minutes, l'appli est en ligne sur `https://<votre-identifiant>.github.io/routealerte/`.
5. Sur le téléphone : ouvrir cette adresse dans Chrome, autoriser la localisation, puis menu ⋮ → **Ajouter à l'écran d'accueil**.

## 4. Activer le ping automatique

1. Dans le dépôt : **Settings** → **Secrets and variables** → **Actions** → **New repository secret** :
   - `SUPABASE_URL` = l'URL du projet
   - `SUPABASE_KEY` = la clé publishable
2. Onglet **Actions** → **Supabase keepalive** → **Run workflow** pour tester tout de suite. Le résultat doit afficher « Ping OK ».
3. Ensuite, il tourne seul tous les 3 jours.

Bon à savoir : GitHub suspend les tâches programmées d'un dépôt public **sans aucune activité pendant 60 jours**. Un simple commit (par exemple une mise à jour de l'appli) suffit à les garder actives ; GitHub prévient aussi par e-mail avant de les suspendre.

## 5. Vérifier que tout marche

- En haut de l'appli, l'indicateur doit afficher **☁ À jour**.
- Faire un relevé (bouton ou ajout sur la carte), puis dans Supabase → **Table Editor** → `hazards` : la ligne apparaît.
- Sur un deuxième téléphone, ouvrir l'appli : le relevé apparaît sur la carte.

Si l'indicateur affiche un message d'erreur, l'onglet **Données** donne le détail (connexions anonymes non activées, mauvaise URL ou clé…).

## Fonctionnement des données

- **Hors ligne** : les relevés sont gardés sur le téléphone (⏳) et envoyés au retour du réseau ; les alertes utilisent la dernière carte reçue.
- **Doublons** : un relevé du même type à moins de 30 m d'un danger connu (ou un tronçon qui le recouvre à plus de 60 %) le **confirme** au lieu de créer un doublon. La position d'un point devient la moyenne des relevés.
- **Historique** : chaque relevé brut est conservé dans la table `reports` (qui, quand, où, résultat).
- **Suppression** : chacun peut supprimer ses propres relevés, pas ceux des autres.
- **Capacité du plan gratuit** : 500 Mo de base, soit des dizaines de milliers de dangers.
