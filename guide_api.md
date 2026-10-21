# Guide d'utilisation de l'API Dzokoli

Ce document décrit les endpoints actuellement implémentés dans le backend Dzokoli, les données attendues et les réponses retournées.

## 1. Informations générales

### URL de base

En développement :

```text
http://localhost:8000
```

Les routes métier sont préfixées par :

```text
/api/v1
```

Exemple :

```text
GET http://localhost:8000/api/v1/users/me
```

### Format des données

- Les requêtes et réponses JSON utilisent `camelCase`.
- Les dates sont au format ISO 8601 UTC.
- Les montants décimaux peuvent être retournés sous forme de nombre ou de chaîne décimale selon la sérialisation du client.
- Les identifiants sont des UUID.
- Les numéros de téléphone utilisent le format E.164, par exemple `+22890123456`.

### Authentification

Sauf mention contraire, les endpoints nécessitent un access token Supabase :

```http
Authorization: Bearer <access_token>
```

Le compte associé au token doit avoir le statut `active`.

### Configuration requise dans Flutter

Lorsque Flutter utilise directement `supabase_flutter` pour Google, Apple ou la gestion de session, l'application a besoin des valeurs publiques suivantes :

```text
API_BASE_URL
SUPABASE_URL
SUPABASE_ANON_KEY
GOOGLE_WEB_CLIENT_ID
```

`SUPABASE_ANON_KEY` désigne la clé publique `anon` historique ou la nouvelle clé `publishable` du projet. Cette clé et l'URL Supabase peuvent être intégrées dans l'application : leur sécurité repose sur l'authentification et les politiques RLS.

Exemple d'initialisation :

```dart
import 'package:supabase_flutter/supabase_flutter.dart';

class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');
  static const googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
}

Future<void> initializeSupabase() async {
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );
}
```

Exemple de lancement Android local sous PowerShell :

```powershell
flutter run `
  --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1 `
  --dart-define=SUPABASE_URL=https://PROJECT_REF.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=VOTRE_CLE_PUBLIQUE `
  --dart-define=GOOGLE_WEB_CLIENT_ID=VOTRE_WEB_CLIENT_ID
```

`10.0.2.2` représente l'ordinateur hôte depuis l'émulateur Android. Sur un téléphone physique, utiliser une adresse accessible depuis le téléphone ou une URL HTTPS de développement.

Les valeurs suivantes ne doivent jamais être placées dans Flutter :

- clé Supabase `service_role` ou clé secrète serveur ;
- Google Client Secret ;
- Twilio Auth Token ;
- mot de passe PostgreSQL ;
- URL ou mot de passe Redis ;
- clé privée Apple `.p8`.

Pour appeler FastAPI après une authentification Supabase :

```dart
final accessToken = Supabase.instance.client.auth.currentSession!.accessToken;

final headers = {
  'Authorization': 'Bearer $accessToken',
  'Content-Type': 'application/json',
};
```

La clé publique Supabase ne doit pas être envoyée à FastAPI dans les requêtes métier. FastAPI reçoit uniquement l'access token utilisateur dans `Authorization`.

### Documentation interactive

Lorsque `DOCS_ENABLED=true` :

```text
GET /docs
GET /redoc
```

## 2. Réponses d'erreur

### Erreur métier

```json
{
  "error": {
    "code": "conflict",
    "message": "The listing is already cancelled",
    "details": {},
    "requestId": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

Le header `X-Request-ID` de la réponse contient le même identifiant. Le client peut aussi fournir son propre `X-Request-ID`.

### Erreur d'authentification

```json
{
  "detail": "Authentication required"
}
```

Codes habituels :

- `401` : token absent, invalide ou expiré ;
- `403` : compte utilisateur non actif ;
- `404` : ressource inexistante ;
- `409` : conflit avec l'état actuel ;
- `413` : fichier trop volumineux ;
- `415` : type de fichier non supporté ;
- `422` : données de requête invalides ;
- `500` ou `502` : erreur interne ou service distant indisponible.

### Erreur de validation 422

Les erreurs de validation FastAPI utilisent le format standard :

```json
{
  "detail": [
    {
      "type": "greater_than",
      "loc": ["body", "rating"],
      "msg": "Input should be greater than 0",
      "input": 0
    }
  ]
}
```

## 3. Système

### Vérifier l'API

```http
GET /health
```

Authentification : non requise.

Réponse `200` :

```json
{
  "status": "ok"
}
```

### Informations de version

```http
GET /
```

Réponse `200` :

```json
{
  "name": "Dzokoli API",
  "version": "0.1.0"
}
```

## 4. Authentification par téléphone

### Demander un OTP

```http
POST /api/v1/auth/phone/request-otp
Content-Type: application/json
```

Authentification : non requise.

Corps :

```json
{
  "phone": "+22890123456"
}
```

Réponse `202` :

```json
{
  "message": "OTP sent"
}
```

### Vérifier l'OTP et se connecter

Le même endpoint est utilisé pour l'inscription et la connexion.

```http
POST /api/v1/auth/phone/verify-otp
Content-Type: application/json
```

Corps :

```json
{
  "phone": "+22890123456",
  "code": "123456"
}
```

Le code doit être numérique et contenir entre 4 et 10 chiffres.

Réponse `200` :

```json
{
  "user": {
    "id": "UUID",
    "phone": "+22890123456",
    "email": null,
    "firstName": null,
    "lastName": null,
    "profilePictureUrl": null,
    "profileCompleted": false
  },
  "session": {
    "accessToken": "ACCESS_TOKEN",
    "refreshToken": "REFRESH_TOKEN",
    "tokenType": "bearer",
    "expiresIn": 3600,
    "expiresAt": 1792148400
  },
  "isNew": true
}
```

`isNew` vaut `true` tant que `profileCompletedAt` n'a pas été renseigné. Le frontend doit alors ouvrir l'onboarding et appeler `PUT /users/me/profile`.

### Rafraîchir la session

```http
POST /api/v1/auth/refresh
Content-Type: application/json
```

Corps :

```json
{
  "refreshToken": "REFRESH_TOKEN"
}
```

Réponse `200` :

```json
{
  "accessToken": "NOUVEL_ACCESS_TOKEN",
  "refreshToken": "NOUVEAU_REFRESH_TOKEN",
  "tokenType": "bearer",
  "expiresIn": 3600,
  "expiresAt": 1792152000
}
```

Le client doit remplacer les deux anciens tokens par ceux de la réponse.

### Déconnexion

```http
POST /api/v1/auth/logout
Authorization: Bearer <access_token>
Content-Type: application/json
```

Corps :

```json
{
  "refreshToken": "REFRESH_TOKEN"
}
```

Réponse : `204 No Content`.

### Google et Apple

Google et Apple sont destinés à être gérés directement dans Flutter avec Supabase Auth. Il n'existe donc pas encore d'endpoint FastAPI `/auth/google` ou `/auth/apple`.

Flux Google mobile :

```text
Flutter → Google Sign-In → ID token Google
        → supabase.auth.signInWithIdToken(...)
        → session Supabase
        → FastAPI avec Authorization: Bearer <accessToken>
```

Exemple simplifié :

```dart
final googleSignIn = GoogleSignIn(
  serverClientId: AppConfig.googleWebClientId,
);

final googleUser = await googleSignIn.signIn();
final googleAuth = await googleUser!.authentication;

final response = await Supabase.instance.client.auth.signInWithIdToken(
  provider: OAuthProvider.google,
  idToken: googleAuth.idToken!,
  accessToken: googleAuth.accessToken!,
);
```

À la première connexion sociale, le trigger crée automatiquement `public.users`. Le frontend appelle ensuite `GET /users/me` : si `profileCompletedAt` vaut `null`, il affiche l'onboarding puis appelle `PUT /users/me/profile`.

Le frontend ne doit pas fusionner automatiquement deux utilisateurs parce qu'ils partagent un email. La liaison téléphone/Google/Apple à un compte existant devra utiliser un parcours explicite et authentifié.

## 5. Utilisateur

### Récupérer mon profil

```http
GET /api/v1/users/me
Authorization: Bearer <access_token>
```

Réponse `200` :

```json
{
  "id": "UUID",
  "phone": "+22890123456",
  "email": "user@example.com",
  "emailVerifiedAt": "2026-10-17T09:00:00Z",
  "firstName": "Ama",
  "lastName": "Mensah",
  "profilePictureUrl": "https://...",
  "profileCompletedAt": "2026-10-17T09:10:00Z",
  "averageRating": "4.75",
  "reviewCount": 12,
  "completedDeliveryCount": 8,
  "status": "active",
  "createdAt": "2026-10-17T09:00:00Z",
  "updatedAt": "2026-10-17T09:10:00Z"
}
```

`averageRating` vaut `0` lorsqu'aucun avis n'a été reçu.

### Finaliser le profil

```http
PUT /api/v1/users/me/profile
Authorization: Bearer <access_token>
Content-Type: multipart/form-data
```

Champs obligatoires :

| Champ | Type | Règle |
|---|---|---|
| `firstName` | texte | 1 à 80 caractères |
| `lastName` | texte | 1 à 80 caractères |
| `profilePicture` | fichier | JPEG, PNG ou WebP, maximum 5 Mo |

Exemple cURL :

```bash
curl -X PUT "http://localhost:8000/api/v1/users/me/profile" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -F "firstName=Ama" \
  -F "lastName=Mensah" \
  -F "profilePicture=@avatar.jpg"
```

Réponse `200` : profil utilisateur complet, au même format que `GET /users/me`.

### Modifier le profil

```http
PATCH /api/v1/users/me
Authorization: Bearer <access_token>
Content-Type: multipart/form-data
```

Champs facultatifs :

- `firstName` ;
- `lastName` ;
- `profilePicture` ;
- `removeProfilePicture`, booléen, valeur par défaut `false`.

Une photo et `removeProfilePicture=true` ne peuvent pas être envoyés ensemble. Un profil déjà finalisé doit conserver une photo de profil.

Réponse `200` : profil mis à jour.

### Supprimer mon compte

```http
DELETE /api/v1/users/me
Authorization: Bearer <access_token>
```

Réponse : `204 No Content`.

La suppression est refusée si le compte possède notamment une livraison active, des fonds, un blocage de portefeuille ou un escrow actif. Le compte est anonymisé avant sa suppression logique dans Supabase Auth.

## 6. Portefeuille

### Récupérer mes portefeuilles

```http
GET /api/v1/wallets/me
Authorization: Bearer <access_token>
```

Réponse `200` :

```json
[
  {
    "id": "UUID",
    "userId": "UUID",
    "currency": "XOF",
    "availableBalance": "10000.00",
    "reservedBalance": "2500.00",
    "pendingBalance": "5000.00",
    "status": "active",
    "createdAt": "2026-10-17T09:00:00Z",
    "updatedAt": "2026-10-17T09:00:00Z"
  }
]
```

- `availableBalance` : utilisable immédiatement ;
- `reservedBalance` : bloqué pour des réservations ;
- `pendingBalance` : paiement reçu en attente de libération.

La recharge et le retrait ne disposent pas encore d'endpoints publics.

## 7. Annonces

### Valeurs autorisées

Types de voyage :

```text
plane | boat
```

Types de colis :

```text
document | clothing | electronics | food | other
```

États d'annonce :

```text
draft | open | closed | expired | cancelled
```

### Créer une annonce et son voyage

```http
POST /api/v1/listings
Authorization: Bearer <access_token>
Content-Type: application/json
```

Corps :

```json
{
  "trip": {
    "type": "plane",
    "departureLocationId": "UUID-LOME-AIRPORT",
    "arrivalLocationId": "UUID-PARIS-AIRPORT",
    "departureAt": "2026-11-10T10:00:00Z",
    "arrivalAt": "2026-11-10T17:30:00Z",
    "transportReference": "AF860"
  },
  "listing": {
    "totalAvailableKg": "20.00",
    "pricePerKg": "5000.00",
    "currency": "XOF",
    "acceptedParcelTypes": ["document", "clothing", "electronics"]
  }
}
```

Règles principales :

- lieux de départ et d'arrivée différents ;
- arrivée postérieure au départ ;
- lieux et pays actifs ;
- un voyage `plane` utilise des aéroports ;
- un voyage `boat` utilise des ports ;
- poids et prix strictement positifs ;
- au moins un type de colis, sans doublon.

Réponse `201` :

```json
{
  "trip": {
    "id": "UUID-TRIP",
    "travelerUserId": "UUID-USER",
    "type": "plane",
    "departureLocationId": "UUID-LOME-AIRPORT",
    "arrivalLocationId": "UUID-PARIS-AIRPORT",
    "departureAt": "2026-11-10T10:00:00Z",
    "arrivalAt": "2026-11-10T17:30:00Z",
    "transportReference": "AF860",
    "status": "scheduled",
    "createdAt": "2026-10-17T10:00:00Z",
    "updatedAt": "2026-10-17T10:00:00Z"
  },
  "listing": {
    "id": "UUID-LISTING",
    "tripId": "UUID-TRIP",
    "totalAvailableKg": "20.00",
    "remainingKg": "20.00",
    "pricePerKg": "5000.00",
    "currency": "XOF",
    "status": "open",
    "closedReason": null,
    "publishedAt": "2026-10-17T10:00:00Z",
    "closedAt": null,
    "acceptedParcelTypes": ["clothing", "document", "electronics"],
    "createdAt": "2026-10-17T10:00:00Z",
    "updatedAt": "2026-10-17T10:00:00Z"
  },
  "cancelledBookingsCount": 0
}
```

### Lister les annonces disponibles

```http
GET /api/v1/listings?limit=20&cursor=CURSOR
Authorization: Bearer <access_token>
```

`limit` est compris entre 1 et 50. `cursor` est absent pour la première page.

Réponse `200` :

```json
{
  "items": [
    {
      "id": "UUID-LISTING",
      "tripId": "UUID-TRIP",
      "travelerUserId": "UUID-USER",
      "tripType": "plane",
      "departureLocationId": "UUID",
      "arrivalLocationId": "UUID",
      "departureAt": "2026-11-10T10:00:00Z",
      "arrivalAt": "2026-11-10T17:30:00Z",
      "transportReference": "AF860",
      "totalAvailableKg": "20.00",
      "remainingKg": "12.50",
      "pricePerKg": "5000.00",
      "currency": "XOF",
      "acceptedParcelTypes": ["document", "clothing"],
      "publishedAt": "2026-10-17T10:00:00Z"
    }
  ],
  "nextCursor": "CURSOR-SUIVANT",
  "hasMore": true
}
```

### Rechercher des annonces

```http
GET /api/v1/listings/search
Authorization: Bearer <access_token>
```

Paramètres facultatifs :

| Paramètre | Description |
|---|---|
| `parcelType` | type de colis accepté |
| `departureLocationId` | lieu de départ |
| `arrivalLocationId` | lieu d'arrivée |
| `minimumKg` | capacité restante minimale |
| `maximumPricePerKg` | prix maximal par kilogramme |
| `currency` | devise ISO sur 3 lettres, ex. `XOF` |
| `limit` | 1 à 50, défaut 20 |
| `cursor` | curseur retourné par la page précédente |

La réponse utilise le même format que la liste des annonces disponibles.

### Récupérer mes annonces

```http
GET /api/v1/listings/me?status=open&limit=20&cursor=CURSOR
Authorization: Bearer <access_token>
```

`status` est facultatif. Cette route retourne aussi les brouillons, annonces fermées, expirées et annulées du propriétaire.

Réponse :

```json
{
  "items": [
    {
      "trip": {},
      "listing": {},
      "cancelledBookingsCount": 0
    }
  ],
  "nextCursor": null,
  "hasMore": false
}
```

Les objets `trip` et `listing` suivent le format complet présenté lors de la création.

### Récupérer une annonce

```http
GET /api/v1/listings/{listingId}
Authorization: Bearer <access_token>
```

Une annonce non disponible reste consultable par son propriétaire, mais pas par les autres utilisateurs.

Réponse : objet complet `{ "trip": ..., "listing": ..., "cancelledBookingsCount": 0 }`.

### Modifier une annonce

```http
PUT /api/v1/listings/{listingId}
Authorization: Bearer <access_token>
Content-Type: application/json
```

Le corps représente l'état éditable complet :

```json
{
  "type": "plane",
  "departureLocationId": "UUID",
  "arrivalLocationId": "UUID",
  "departureAt": "2026-11-11T10:00:00Z",
  "arrivalAt": "2026-11-11T17:30:00Z",
  "transportReference": "AF860",
  "totalAvailableKg": "18.00",
  "pricePerKg": "5500.00",
  "currency": "XOF",
  "acceptedParcelTypes": ["document", "clothing"]
}
```

Une modification majeure du voyage, une capacité devenue insuffisante ou la suppression d'un type de colis déjà réservé entraîne l'annulation des réservations encore annulables et la libération de leurs fonds. La réponse indique le nombre dans `cancelledBookingsCount`.

La modification est refusée lorsque la livraison a commencé.

### Annuler une annonce

```http
POST /api/v1/listings/{listingId}/cancel
Authorization: Bearer <access_token>
```

L'opération annule les réservations encore annulables, libère les fonds, puis annule l'annonce et le voyage dans une transaction. Elle est refusée après le début d'une livraison.

Réponse `200` : détails de l'annonce avec `status: "cancelled"` et `cancelledBookingsCount`.

## 8. Avis

### Créer un avis

```http
POST /api/v1/reviews
Authorization: Bearer <access_token>
Content-Type: application/json
```

Corps :

```json
{
  "bookingId": "UUID-BOOKING",
  "rating": 5,
  "comment": "Livraison rapide et colis bien conservé."
}
```

Règles :

- note entière de 1 à 5 ;
- commentaire facultatif, maximum 1000 caractères ;
- seul l'acheteur ayant réservé peut noter ;
- réservation `completed` et shipment `delivered` ;
- un seul avis par réservation ;
- le voyageur est automatiquement la personne notée.

Réponse `201` :

```json
{
  "id": "UUID-REVIEW",
  "bookingId": "UUID-BOOKING",
  "reviewerUserId": "UUID-BUYER",
  "reviewedUserId": "UUID-TRAVELER",
  "rating": 5,
  "comment": "Livraison rapide et colis bien conservé.",
  "createdAt": "2026-10-17T12:00:00Z",
  "updatedAt": "2026-10-17T12:00:00Z"
}
```

### Mes avis reçus

```http
GET /api/v1/reviews/me?limit=20&offset=0
Authorization: Bearer <access_token>
```

### Avis reçus par un utilisateur

```http
GET /api/v1/reviews/users/{userId}?limit=20&offset=0
Authorization: Bearer <access_token>
```

Réponse des deux endpoints :

```json
{
  "items": [],
  "limit": 20,
  "offset": 0,
  "hasMore": false
}
```

## 9. Messagerie

### Principes d'utilisation

Le client doit utiliser :

1. `GET /conversations/bootstrap` lors du chargement initial ;
2. le WebSocket global `/conversations/inbox/ws` pour recevoir les événements en temps réel et rejouer ceux manqués hors ligne ;
3. le WebSocket d'une conversation pour envoyer des messages, signaler la lecture et transmettre la saisie ;
4. les endpoints HTTP d'historique uniquement lors de l'ouverture d'une conversation ou du chargement de messages plus anciens.

Il ne faut pas interroger périodiquement les messages toutes les quelques secondes.

### Créer une conversation directe

```http
POST /api/v1/conversations
Authorization: Bearer <access_token>
Content-Type: application/json
```

Corps :

```json
{
  "type": "direct",
  "participants": [
    {
      "userId": "UUID-UTILISATEUR-CONNECTE",
      "role": "member"
    },
    {
      "userId": "UUID-AUTRE-UTILISATEUR",
      "role": "member"
    }
  ]
}
```

Une conversation directe exige exactement deux participants distincts. L'utilisateur connecté doit être inclus. Les groupes de livraison seront créés automatiquement par le processus de réservation et ne peuvent pas être créés avec cet endpoint.

Réponse `201` :

```json
{
  "id": "UUID-CONVERSATION",
  "type": "direct",
  "directKey": "...",
  "createdByUserId": "UUID",
  "status": "active",
  "participants": [
    {
      "userId": "UUID",
      "role": "member",
      "firstName": "Ama",
      "lastName": "Mensah",
      "profilePictureUrl": "https://...",
      "joinedAt": "2026-10-17T12:00:00Z",
      "leftAt": null,
      "lastReadAt": null
    }
  ],
  "unreadCount": 0,
  "lastMessage": null,
  "lastMessageAt": null,
  "closedAt": null,
  "createdAt": "2026-10-17T12:00:00Z",
  "updatedAt": "2026-10-17T12:00:00Z"
}
```

### Bootstrap initial

```http
GET /api/v1/conversations/bootstrap?conversation_limit=50
Authorization: Bearer <access_token>
```

Réponse :

```json
{
  "conversations": {
    "items": [],
    "limit": 50,
    "offset": 0,
    "hasMore": false
  },
  "lastSequenceId": 124
}
```

Le client conserve localement `lastSequenceId`. Il ne doit pas remplacer un curseur local plus récent par une valeur plus ancienne.

### Lister les conversations

```http
GET /api/v1/conversations?limit=20&offset=0
Authorization: Bearer <access_token>
```

Réponse : `ConversationPage`, identique à `conversations` dans le bootstrap.

### Récupérer une conversation

```http
GET /api/v1/conversations/{conversationId}
Authorization: Bearer <access_token>
```

Seul un participant actif peut la consulter.

### Historique des messages

```http
GET /api/v1/conversations/{conversationId}/messages?limit=30&before=2026-10-17T12:00:00Z
Authorization: Bearer <access_token>
```

- `limit` : 1 à 100 ;
- `before` : date du plus ancien message déjà chargé, facultative.

Réponse :

```json
{
  "items": [
    {
      "id": "UUID-MESSAGE",
      "conversationId": "UUID-CONVERSATION",
      "senderUserId": "UUID",
      "replyToMessageId": null,
      "clientMessageId": "UUID-GENERE-PAR-LE-CLIENT",
      "type": "text",
      "content": "Bonjour",
      "attachments": [],
      "createdAt": "2026-10-17T12:10:00Z",
      "editedAt": null,
      "deletedAt": null
    }
  ],
  "nextCursor": "2026-10-17T11:50:00Z",
  "hasMore": true
}
```

### Fermer une conversation

```http
POST /api/v1/conversations/{conversationId}/close
Authorization: Bearer <access_token>
```

La fermeture manuelle concerne les conversations directes. Les groupes de livraison sont fermés automatiquement à la fin de la livraison.

### Récupération HTTP des événements

```http
GET /api/v1/conversations/inbox/events?after_sequence_id=124&limit=100
Authorization: Bearer <access_token>
```

Cette route sert à la récupération ou au diagnostic, pas au polling permanent.

Réponse :

```json
{
  "items": [],
  "nextSequenceId": 124,
  "hasMore": false
}
```

### WebSocket global de messagerie

```text
WS /api/v1/conversations/inbox/ws?afterSequenceId=124
Authorization: Bearer <access_token>
```

Pour les clients ne permettant pas un header WebSocket :

```text
WS /api/v1/conversations/inbox/ws?accessToken=TOKEN&afterSequenceId=124
```

Le header est préférable car un token dans l'URL peut apparaître dans les logs.

Événements reçus :

- `inbox.connected` ;
- `inbox.event` ;
- `inbox.synced` ;
- `inbox.acknowledged` ;
- `pong` ;
- `error`.

Exemple `inbox.event` :

```json
{
  "event": "inbox.event",
  "data": {
    "sequenceId": 125,
    "userId": "UUID",
    "event": "message.created",
    "conversationId": "UUID",
    "actorUserId": "UUID",
    "payload": {},
    "message": {
      "id": "UUID",
      "conversationId": "UUID",
      "senderUserId": "UUID",
      "replyToMessageId": null,
      "clientMessageId": "UUID",
      "type": "text",
      "content": "Bonjour",
      "attachments": [],
      "createdAt": "2026-10-17T12:10:00Z",
      "editedAt": null,
      "deletedAt": null
    },
    "createdAt": "2026-10-17T12:10:00Z",
    "acknowledgedAt": null
  }
}
```

Demander la page suivante :

```json
{
  "event": "inbox.sync",
  "data": {
    "afterSequenceId": 125,
    "limit": 100
  }
}
```

Confirmer le traitement durable des événements :

```json
{
  "event": "inbox.ack",
  "data": {
    "sequenceId": 125
  }
}
```

Le client doit sauvegarder localement le dernier `sequenceId` traité. Après une reconnexion, il le transmet dans `afterSequenceId`. Les messages envoyés pendant une déconnexion sont persistés puis rejoués.

### WebSocket d'une conversation

```text
WS /api/v1/conversations/{conversationId}/ws
Authorization: Bearer <access_token>
```

Événement de connexion reçu :

```json
{
  "event": "connected",
  "data": {
    "conversationId": "UUID",
    "userId": "UUID"
  }
}
```

Envoyer un message texte :

```json
{
  "event": "message.send",
  "data": {
    "clientMessageId": "UUID-UNIQUE-GENERE-PAR-LE-CLIENT",
    "type": "text",
    "content": "Bonjour",
    "replyToMessageId": null,
    "attachments": []
  }
}
```

Réponse d'acceptation :

```json
{
  "event": "message.accepted",
  "data": {
    "clientMessageId": "UUID",
    "messageId": "UUID"
  }
}
```

`clientMessageId` rend l'envoi idempotent : lors d'une nouvelle tentative avec le même UUID, le serveur ne doit pas créer un doublon.

Marquer comme lu :

```json
{
  "event": "conversation.read",
  "data": {}
}
```

Indiquer la saisie :

```json
{ "event": "typing.start", "data": {} }
```

```json
{ "event": "typing.stop", "data": {} }
```

Maintenir la connexion :

```json
{ "event": "ping", "data": {} }
```

### Pièces jointes

Types :

```text
image | video | audio | file
```

MIME autorisés : JPEG, PNG, WebP, GIF, MP4, WebM, MPEG audio, MP4 audio, OGG, WebM audio et PDF. Taille maximale : 50 Mo.

#### 1. Générer une URL d'upload

```http
POST /api/v1/conversations/{conversationId}/attachments/upload-url
Authorization: Bearer <access_token>
Content-Type: application/json
```

```json
{
  "type": "image",
  "fileName": "photo.jpg",
  "mimeType": "image/jpeg",
  "sizeBytes": 245000
}
```

Réponse :

```json
{
  "storagePath": "CONVERSATION_ID/USER_ID/fichier.jpg",
  "signedUrl": "https://...",
  "token": "..."
}
```

#### 2. Envoyer le fichier

Le frontend envoie directement le contenu du fichier à l'URL signée Supabase, avec exactement le MIME et la taille annoncés.

#### 3. Confirmer l'upload

```http
POST /api/v1/conversations/{conversationId}/attachments/confirm
Authorization: Bearer <access_token>
Content-Type: application/json
```

```json
{
  "type": "image",
  "storagePath": "CONVERSATION_ID/USER_ID/fichier.jpg",
  "originalFileName": "photo.jpg",
  "mimeType": "image/jpeg",
  "sizeBytes": 245000,
  "durationSeconds": null,
  "width": 1080,
  "height": 720
}
```

Réponse : mêmes informations avec `"verified": true`.

#### 4. Envoyer le message WebSocket

```json
{
  "event": "message.send",
  "data": {
    "clientMessageId": "UUID",
    "type": "attachment",
    "content": "Voici la photo du colis",
    "attachments": [
      {
        "type": "image",
        "storagePath": "CONVERSATION_ID/USER_ID/fichier.jpg",
        "originalFileName": "photo.jpg",
        "mimeType": "image/jpeg",
        "sizeBytes": 245000,
        "durationSeconds": null,
        "width": 1080,
        "height": 720
      }
    ]
  }
}
```

Un message vocal utilise `type: "voice"` et doit contenir exactement une pièce jointe audio.

#### URL de téléchargement

```http
GET /api/v1/conversations/{conversationId}/attachments/{attachmentId}/download-url?expires_in=900
Authorization: Bearer <access_token>
```

`expires_in` est compris entre 60 et 3600 secondes.

Réponse :

```json
{
  "attachmentId": "UUID",
  "signedUrl": "https://...",
  "expiresIn": 900
}
```

## 10. Fonctionnalités non encore exposées

Les schémas ou dossiers existent, mais les endpoints suivants ne sont pas encore implémentés :

- pays et localisations ;
- voyages indépendants ;
- réservations ;
- shipments, colis, destinataires et preuves ;
- recharge et retrait du portefeuille ;
- paiements et escrow ;
- litiges ;
- notifications push ;
- favoris ;
- endpoints FastAPI dédiés à Google et Apple (la connexion mobile passe directement par Supabase Auth) ;
- authentification par email.

Ils ne doivent pas être consommés par le frontend tant qu'ils n'apparaissent pas dans ce guide et dans `/docs`.

## 11. Ordre d'intégration frontend recommandé

1. Demander puis vérifier l'OTP.
2. Sauvegarder `accessToken` et `refreshToken` dans un stockage sécurisé.
3. Si `isNew=true`, finaliser le profil avec nom, prénom et photo.
4. Charger `GET /users/me` et `GET /wallets/me`.
5. Charger les annonces disponibles.
6. Pour la messagerie, exécuter le bootstrap une fois.
7. Ouvrir le WebSocket global avec le dernier `sequenceId` local.
8. Ouvrir le WebSocket d'une conversation seulement lorsque nécessaire.
9. Rafraîchir la session avant ou après expiration de l'access token.
10. À la déconnexion, appeler `/auth/logout`, puis supprimer localement les tokens.
