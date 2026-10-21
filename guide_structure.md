# Guide du projet W-Track API

## 1. Présentation

W-Track API est le backend de l'application mobile W-Track. Il fournit les services d'authentification, de gestion financière, de synchronisation et de reporting utilisés par le client mobile.

Le projet repose principalement sur :

- **FastAPI** pour l'API HTTP ;
- **Supabase Auth** pour l'identité et les sessions ;
- **PostgreSQL/Supabase** pour les données ;
- **Supabase Storage** pour les pièces jointes et les photos ;
- **Docker** pour empaqueter et déployer l'API ;
- **GitHub Actions** pour les migrations et les sauvegardes ;
- **n8n** pour réceptionner les sauvegardes et les transférer vers Google Drive.

Toutes les routes métier sont versionnées sous `/api/v1`. Les routes `/` et `/health` servent au contrôle de disponibilité.

## 2. Structure générale

```text
api/
├── .github/
│   └── workflows/             # Migrations et sauvegardes automatisées
├── config/
│   └── supabase_client.py     # Création et configuration des clients Supabase
├── docs/                      # Documentation complémentaire de l'API
├── features/                  # Modules fonctionnels FastAPI
├── public/                    # Ressources publiques du projet
├── supabase/
│   ├── migrations/            # Historique SQL versionné de la base
│   ├── scripts/               # Scripts manuels hors migrations
│   ├── templates/             # Modèles associés à Supabase
│   └── config.toml            # Configuration locale Supabase
├── .dockerignore              # Fichiers exclus de l'image Docker
├── .env.example               # Liste des variables de configuration
├── docker-compose.yml         # Exécution d'une image déjà construite
├── Dockerfile                 # Construction de l'image de l'API
├── main.py                    # Point d'entrée FastAPI
├── README.docker.md           # Aide spécifique à Docker
└── requirements.txt           # Dépendances Python
```

Les fichiers `.env`, `.env.dev` et `.env.prod` contiennent des secrets ou des configurations propres aux environnements. Ils ne doivent pas être intégrés dans une image publique ni poussés dans Git.

## 3. Organisation d'un module fonctionnel

Le dossier `features/` regroupe le code par domaine métier. Un module contient généralement :

- un fichier `*_route.py` : routes HTTP, paramètres, dépendances et codes de réponse ;
- un fichier `*_models.py` : modèles Pydantic d'entrée et de sortie ;
- un fichier `*_service.py` : logique métier et accès à Supabase.

Cette séparation évite de placer la logique métier directement dans les routes.

| Module | Responsabilité principale |
|---|---|
| `auth` | OTP par email, vérification, renouvellement et fermeture de session |
| `users` | Profil, préférences et suppression du compte |
| `accounts` | Comptes financiers et soldes |
| `transactions` | Revenus, dépenses, transferts et pièces jointes |
| `categories` | Catégories globales et personnelles, avec hiérarchie |
| `budgets` | Budgets, périodes et enveloppes |
| `recurring_operations` | Opérations récurrentes, exécution, pause et reprise |
| `analytics` | Tableau de bord, statistiques et agrégations |
| `currencies` | Devises, taux et conversions |
| `notifications` | Notifications applicatives et appareils |
| `bootstrap` | Chargement initial groupé du tableau de bord mobile |
| `sync` | Synchronisation incrémentale et suppressions hors ligne |
| `catalog` | Référentiels consommés par l'application |
| `app_config` | Versions mobiles, fonctionnalités et configuration distante |
| `exports` | Manifestes et exports CSV |
| `security` | Migration des champs chiffrés et protections transversales |

`main.py` crée l'application, installe les middlewares, configure CORS et les gestionnaires d'erreurs, puis enregistre tous ces routeurs.

## 4. Cycle d'une requête

Une requête suit globalement ce chemin :

```text
Application mobile
    -> middleware de sécurité et limite de débit
    -> route FastAPI
    -> validation Pydantic
    -> service métier
    -> client Supabase/PostgreSQL/Storage
    -> modèle de réponse JSON
```

Les erreurs attendues sont traduites en réponses HTTP cohérentes. Un identifiant de requête permet de rapprocher les erreurs mobiles des journaux de l'API.

## 5. Utilisateurs et authentification OTP

### 5.1 Inscription

L'inscription par email utilise notamment :

```http
POST /api/v1/auth/email/signup/request-otp
```

L'API transmet l'email et les métadonnées du profil à Supabase Auth. Pour une inscription, Supabase est autorisé à créer l'utilisateur. Le nom d'utilisateur demandé par l'application est placé dans les métadonnées d'authentification.

Supabase envoie ensuite un email contenant le code. Le modèle d'email doit afficher `{{ .Token }}`. L'utilisation de `{{ .ConfirmationURL }}` produit un lien magique au lieu d'un code visible.

Exemple minimal de modèle Supabase :

```html
<h2>Votre code de connexion W-Track</h2>
<p>Utilisez ce code pour vous connecter ou créer votre compte :</p>
<h1 style="font-size:32px; letter-spacing:6px;">{{ .Token }}</h1>
<p>Ce code expire rapidement. Ne le partagez avec personne.</p>
```

Un logo public peut être intégré avec une balise `img` pointant vers un objet public de Supabase Storage.

### 5.2 Connexion

Pour une connexion existante, le client appelle :

```http
POST /api/v1/auth/email/login/request-otp
```

Dans ce mode, la création automatique d'un nouveau compte est désactivée. La route historique `/api/v1/auth/email/request-otp` reste également présente.

### 5.3 Vérification du code

Le code reçu est envoyé à :

```http
POST /api/v1/auth/email/verify-otp
```

L'API appelle Supabase Auth avec le type `email`. En cas de succès, la réponse contient notamment un **access token** et un **refresh token**. Le mobile envoie ensuite l'access token dans chaque appel protégé :

```http
Authorization: Bearer <access_token>
```

Le renouvellement passe par `POST /api/v1/auth/refresh`, la fermeture de session par `POST /api/v1/auth/logout`, et l'utilisateur authentifié peut être consulté via `GET /api/v1/auth/me`.

### 5.4 Création du profil applicatif

Supabase conserve l'identité dans `auth.users`. Un trigger PostgreSQL crée automatiquement les données applicatives correspondantes dans `public.users` et `public.user_preferences`. Les métadonnées fournies à l'inscription servent à initialiser le profil, la langue et la devise préférée.

Il ne faut donc pas créer manuellement un second utilisateur public depuis le mobile après la validation OTP.

### 5.5 Suppression d'un compte

`DELETE /api/v1/users/me` supprime l'identité via l'API d'administration Supabase. Les relations configurées en cascade nettoient les données appartenant à l'utilisateur. Le service collecte également les chemins des pièces jointes afin de retirer les objets associés du Storage.

Cette opération nécessite la clé de service Supabase côté serveur. Cette clé ne doit jamais être envoyée à l'application mobile.

## 6. Supabase et la base de données

### 6.1 Clients et clés

L'API distingue trois éléments :

- `SUPABASE_URL` : URL du projet ;
- `SUPABASE_ANON_KEY` : opérations réalisées dans le contexte d'un utilisateur ;
- `SUPABASE_SERVICE_KEY` : tâches administratives serveur qui doivent contourner les politiques ordinaires.

Le JWT du mobile est transmis à Supabase pour que les politiques RLS identifient l'utilisateur courant. La clé de service est réservée aux opérations explicitement administratives.

### 6.2 Tables métier principales

La base contient notamment :

- `users` et `user_preferences` ;
- `financial_accounts` ;
- `categories` ;
- `transactions` ;
- `budgets` ;
- `recurring_operations` ;
- `notifications` et `notification_devices` ;
- `exchange_rates` ;
- `sync_deleted_items` pour les suppressions synchronisées ;
- les tables de suivi liées au chiffrement.

Certaines catégories sont globales (`user_id` nul), tandis que les catégories personnalisées appartiennent à un utilisateur.

### 6.3 RLS, contraintes et triggers

La sécurité des données ne dépend pas uniquement du code Python. Les migrations activent la **Row Level Security** et définissent des politiques d'accès par propriétaire. Elles ajoutent également des contraintes et triggers qui :

- maintiennent les soldes des comptes ;
- vérifient la propriété des objets associés ;
- bloquent certaines opérations sur un compte archivé ;
- contrôlent les devises des comptes et transferts ;
- gèrent la hiérarchie des catégories ;
- enregistrent les suppressions nécessaires à la synchronisation.

Une modification métier importante doit donc être examinée à la fois dans le service Python et dans les migrations SQL.

### 6.4 Storage

Supabase Storage est utilisé pour les pièces jointes de transaction et les photos de profil. Les URLs signées sont temporaires pour les objets privés. La taille maximale d'une pièce jointe et la durée d'une URL signée sont configurables par variables d'environnement.

## 7. Principaux flux métier

### Bootstrap mobile

`GET /api/v1/bootstrap/?sync_alerts=false&notifications_limit=5` regroupe les informations nécessaires au chargement du tableau de bord : profil, préférences, comptes, indicateurs, transactions et notifications. Cela réduit le nombre d'allers-retours réseau au démarrage.

La devise préférée provient du profil utilisateur et est transmise au calcul du tableau de bord.

### Transactions et soldes

Une transaction est créée dans le contexte de l'utilisateur authentifié. Les règles SQL et les services contrôlent le compte, la catégorie, la devise et le type de mouvement. Les transferts utilisent deux comptes et peuvent nécessiter un taux lorsque les devises diffèrent.

### Synchronisation hors ligne

`GET /api/v1/sync/changes` permet au mobile de demander uniquement les changements postérieurs à son dernier curseur. Les tombstones de `sync_deleted_items` signalent aussi les ressources supprimées afin que le mobile puisse les retirer localement.

### Opérations récurrentes

Le module permet de créer, exécuter, suspendre, reprendre, ignorer ou arrêter une opération récurrente. L'exécution produit une transaction selon les règles métier et la date d'échéance.

### Devises

Le module fournit les préférences, les taux de change, la conversion et une synchronisation protégée des taux externes. Les taux de secours sont configurables pour limiter les interruptions.

## 8. Sécurité applicative

Les protections principales sont :

- validation des entrées par Pydantic ;
- authentification Bearer pour les routes privées ;
- RLS Supabase pour isoler les utilisateurs ;
- CORS configurable ;
- taille maximale des requêtes ;
- limitation de débit globale et par famille de routes ;
- identifiants de requête et journalisation des erreurs ;
- chiffrement optionnel des champs sensibles ;
- bearer interne pour les opérations techniques sensibles.

Le chiffrement utilise une clé `MONETRA_FIELD_ENCRYPTION_KEY`. Une valeur chiffrée est marquée par le préfixe `enc:v1:` et certains champs disposent d'un index aveugle HMAC pour permettre les recherches sans stocker la valeur en clair.

En production :

- utiliser un `INTERNAL_API_BEARER` long et aléatoire ;
- ne jamais exposer `SUPABASE_SERVICE_KEY`, `SUPABASE_JWT_SECRET` ou la clé de chiffrement ;
- limiter précisément les origines CORS ;
- désactiver la documentation interactive si elle n'est pas nécessaire ;
- conserver les secrets uniquement dans le gestionnaire de secrets du serveur ou de GitHub.

La limitation de débit actuelle est conservée en mémoire dans le processus. Avec plusieurs instances API, chaque instance possède donc son propre compteur. Un stockage partagé, par exemple Redis, serait requis pour une limite strictement globale.

## 9. Configuration

Copier `.env.example` vers `.env`, puis renseigner les valeurs adaptées à l'environnement. Les variables sont organisées ainsi :

- **Supabase** : URL, clé anonyme, clé de service, secret JWT et options HTTP ;
- **accès internes** : bearer technique et comptes réservés à la validation Google Play ;
- **HTTP** : CORS, identifiant de requête et taille maximale ;
- **chiffrement** : activation et clé Fernet ;
- **API** : activation de Swagger/ReDoc ;
- **rate limiting** : activation, proxy de confiance, quotas et périodes ;
- **limites métier** : nombres maximaux de comptes et budgets ;
- **Storage** : bucket, taille des pièces jointes et durée des URLs ;
- **application mobile** : versions minimale/recommandée et feature flags ;
- **devises** : taux de secours et taux utilisés pour certains transferts.

Les secrets GitHub `SUPABASE_DB_URL`, `N8N_WEBHOOK_URL`, `N8N_WEBHOOK_USERNAME` et `N8N_WEBHOOK_PASSWORD` concernent les workflows et ne doivent pas être placés dans le code.

Une URL PostgreSQL placée dans un secret doit encoder les caractères réservés du mot de passe. Par exemple, `@` devient `%40`. Dans pgAdmin, le mot de passe doit au contraire être saisi normalement, sans encodage URL.

## 10. Démarrage local

Sous PowerShell :

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

L'utilisation de `python -m uvicorn` évite les erreurs provoquées par un exécutable `uvicorn.exe` créé dans une ancienne copie du virtualenv.

Contrôles utiles :

```text
GET http://localhost:8000/health
GET http://localhost:8000/docs
```

La documentation `/docs` n'est disponible que si elle est activée par la configuration.

## 11. Docker

### Construction

Le `Dockerfile` installe Python et les dépendances, copie l'application puis configure Uvicorn comme commande par défaut.

```powershell
docker build --pull -t monetra-api:1.0.1 .
```

### Publication dans le registre

```powershell
docker tag monetra-api:1.0.1 217.154.112.152:5000/monetra:1.0.1
docker push 217.154.112.152:5000/monetra:1.0.1
```

Il faut incrémenter la version lorsqu'une nouvelle image contient des changements à déployer. Republier une ancienne étiquette rend les déploiements plus difficiles à tracer.

### Exécution

`docker-compose.yml` contient uniquement une propriété `image` et aucun bloc `build`. Il ne dépend donc pas du `Dockerfile` au moment de l'exécution. Le `Dockerfile` reste nécessaire pour construire une nouvelle version de l'image.

```powershell
$env:MONETRA_API_IMAGE="217.154.112.152:5000/monetra:1.0.1"
docker compose pull
docker compose up -d
docker compose logs -f monetra-api
```

Le fichier `.env` reste nécessaire au conteneur car il fournit sa configuration d'exécution. Le code et ses dépendances sont déjà incorporés dans l'image.

## 12. Migrations Supabase

Les migrations sont stockées dans `supabase/migrations/`. Elles représentent l'historique officiel du schéma et ne doivent normalement plus être modifiées après leur application en production. Toute évolution crée un nouveau fichier horodaté.

Le workflow `.github/workflows/supabase-prod-migration.yml` :

- s'exécute automatiquement sur un push vers `main` ;
- peut être lancé manuellement avec `workflow_dispatch` ;
- utilise `SUPABASE_DB_URL` ;
- exécute `supabase db push --db-url "$SUPABASE_DB_URL"`.

Un push sur une autre branche ne déclenche donc pas automatiquement les migrations de production.

Avant un déploiement, vérifier particulièrement :

- que l'URL cible bien le projet de production ;
- que le mot de passe PostgreSQL est correct ;
- que les caractères réservés sont encodés dans l'URL ;
- qu'une sauvegarde récente est disponible ;
- que la migration a été testée sur un environnement non critique.

## 13. Sauvegardes

Le workflow `.github/workflows/supabase-backup.yml` s'exécute chaque jour à **02:00, heure Africa/Lome**, et peut aussi être lancé manuellement.

Il produit séparément :

- `roles.sql` ;
- `schema.sql` ;
- `data.sql`.

Ces fichiers sont placés dans une archive `supabase-backup-<date>.tar.gz`, envoyée en `multipart/form-data` dans le champ binaire `data`, puis supprimée du runner GitHub.

Le webhook n8n doit :

1. être actif et utiliser son **Production URL** pour les exécutions GitHub ;
2. accepter la méthode `POST` ;
3. utiliser **Basic Auth** avec les mêmes identifiants que les secrets GitHub ;
4. recevoir le fichier dans le champ binaire `data` ;
5. transférer ce binaire vers Google Drive ;
6. répondre immédiatement ou posséder un nœud `Respond to Webhook` réellement relié au flux.

L'URL `/webhook-test/...` n'est valide que pendant une écoute de test n8n et généralement pour un seul appel. Le workflow automatisé doit utiliser `/webhook/...`.

Une sauvegarde n'est considérée fiable qu'après un test de restauration sur une base séparée. Il faut aussi définir une politique de rétention et surveiller les échecs GitHub Actions/n8n.

## 14. Données de test et historique des migrations

Le script `supabase/scripts/cleanup_all_test_users.sql` sert à effacer les utilisateurs de test lorsque la base ne contient encore aucun vrai utilisateur. Il supprime les lignes de `auth.users`; les cascades configurées nettoient les données relationnelles associées.

Ce script :

- n'est pas placé dans `supabase/migrations/` ;
- ne crée ni ne supprime de table ;
- ne modifie pas l'historique des migrations ;
- doit être exécuté volontairement et avec une sauvegarde récente.

Les fichiers physiques du Storage peuvent nécessiter un nettoyage distinct si leur suppression n'est pas couverte par le flux applicatif.

## 15. Ajouter une fonctionnalité

Pour ajouter un domaine métier :

1. créer un dossier dans `features/` ;
2. définir les modèles Pydantic ;
3. placer la logique dans un service ;
4. créer le routeur sous `/api/v1/...` ;
5. enregistrer le routeur dans `main.py` ;
6. créer une nouvelle migration si le schéma change ;
7. ajouter les politiques RLS, contraintes et index nécessaires ;
8. documenter les nouvelles variables dans `.env.example` ;
9. tester les cas autorisés, interdits, concurrents et hors ligne ;
10. vérifier `/docs`, `/health` et les journaux avant le déploiement.

## 16. Checklist de mise en production

- Variables et secrets de production renseignés sans valeur de développement.
- OTP reçu et vérifié sur une vraie adresse de test.
- RLS contrôlée avec au moins deux utilisateurs distincts.
- Suppression de compte testée, y compris les fichiers Storage.
- Migration réussie et sauvegarde restaurable disponible.
- Image Docker versionnée, poussée et référencée sur le serveur.
- `/health` accessible après redémarrage.
- CORS, limites de débit et taille de requête adaptés à la production.
- Webhook n8n actif, authentifié et configuré avec l'URL de production.
- Alertes ou vérifications régulières mises en place pour les workflows GitHub.

