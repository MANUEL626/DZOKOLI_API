# Guide fonctionnel de Dzokoli

Ce document conserve les décisions fonctionnelles prises pour Dzokoli. Il devra évoluer avec les parcours utilisateur, les règles métier et les futures intégrations techniques.

## 1. Objectif de l’application

Dzokoli met en relation :

- un voyageur qui propose une partie de son poids de bagage disponible ;
- un expéditeur qui réserve et paie une partie de cet espace ;
- éventuellement un destinataire différent de l’expéditeur, chargé de récupérer le colis à l’arrivée.

Dzokoli facilite la réservation, le paiement sécurisé, la communication et la confirmation de remise. Les règles aériennes, douanières et légales applicables doivent toujours être respectées.

## 2. Rôles fonctionnels

Un même compte peut jouer plusieurs rôles selon une transaction.

### Voyageur ou transporteur — User 1

- publie une annonce de voyage ;
- indique son trajet, sa date, le poids disponible, son tarif et les types de colis acceptés ;
- reçoit automatiquement les demandes tant que son annonce est ouverte et que le poids demandé est disponible ;
- peut clôturer son annonce afin de ne plus recevoir de nouvelles demandes ;
- reçoit le colis à son domicile avant le départ ;
- photographie l’état du colis avant d’en confirmer la prise en charge ;
- remet le colis au destinataire autorisé à l’arrivée ;
- reçoit son paiement après confirmation de la livraison.

### Acheteur ou expéditeur — User 2

- choisit une annonce ;
- réserve un nombre de kilogrammes ;
- décrit le colis et déclare son contenu ;
- valide son moyen de paiement lors de la réservation ;
- remet le colis au voyageur ;
- choisit qui récupérera le colis à destination.

### Destinataire — User 2 ou User 3

- récupère le colis à l’arrivée ;
- présente une preuve de récupération valide ;
- confirme la remise du colis.

Le destinataire n’est donc pas un nouveau type de compte permanent. C’est un rôle attribué pour une livraison précise.

## 3. Principe recommandé

Une réservation doit contenir une propriété `recipientType` :

- `buyer` : l’acheteur récupère lui-même le colis ;
- `thirdParty` : une autre personne récupère le colis.

La logique de transport, de paiement et de suivi reste identique. Seules l’identité de la personne autorisée et la méthode de confirmation de remise changent.

## 4. Parcours commun de réservation

1. User 1 publie une annonce avec son trajet et son poids disponible.
2. User 2 choisit l’annonce et indique le poids souhaité.
3. Dzokoli vérifie que le poids est encore disponible.
4. User 2 décrit le colis et confirme que son contenu est autorisé.
5. User 2 choisit le destinataire : « Moi-même » ou « Une autre personne ».
6. User 2 valide son moyen de paiement ; une préautorisation peut être effectuée, mais le débit intervient au premier scan QR.
7. Le moyen de paiement est vérifié ou le montant est préautorisé, mais User 2 n’est débité qu’à la prise en charge effective du colis.
8. La demande est acceptée automatiquement et le poids réservé est retiré du poids encore disponible dans l’annonce.
9. User 2 fait livrer le colis au domicile de User 1 et les deux utilisateurs peuvent organiser la remise dans la messagerie.
10. Avant la prise en charge, User 1 photographie l’état du colis dans l’application.
11. User 1 scanne un premier QR code présenté par User 2. Ce scan confirme la réception du colis et déclenche le débit de User 2.
12. Le montant débité reste sécurisé par Dzokoli pendant le transport.
13. À destination, User 1 scanne un second QR code présenté par le destinataire autorisé.
14. Ce second scan marque la livraison comme terminée et permet le versement à User 1 selon le délai de paiement qui sera défini.
15. User 2 peut ensuite attribuer une note et laisser un avis à User 1.

Si User 1 ne souhaite plus recevoir de demandes, il peut clôturer manuellement son annonce. Une annonce est également clôturée automatiquement lorsque son poids restant atteint zéro. La clôture empêche uniquement les nouvelles demandes et ne supprime pas les réservations déjà confirmées.

## 5. Cas 1 — User 2 récupère lui-même le colis

Lors de la réservation, User 2 choisit « Je récupère moi-même le colis ».

### Informations enregistrées

- `buyerId` : identifiant de User 2 ;
- `recipientType` : `buyer` ;
- `recipientUserId` : même identifiant que `buyerId` ;
- nom et numéro vérifiés récupérés depuis le profil de User 2.

### Remise à destination

1. User 1 signale son arrivée.
2. User 2 reçoit une notification.
3. L’application génère ou affiche un QR code et un code à usage unique.
4. User 2 présente le QR code à User 1.
5. User 1 scanne le QR code ou saisit le code.
6. L’application affiche l’identité attendue avant confirmation.
7. La remise est confirmée, la livraison est terminée et User 2 peut noter User 1.

Cette solution évite qu’une simple capture d’écran suffise : le code doit être à usage unique, limité dans le temps et invalidé après utilisation.

## 6. Cas 2 — User 3 récupère le colis

Lors de la réservation, User 2 choisit « Une autre personne récupérera le colis ».

### Informations demandées à User 2

- nom complet de User 3 ;
- numéro de téléphone au format international ;
- adresse e-mail facultative ;
- relation ou instruction facultative ;
- consentement à transmettre à User 3 les informations nécessaires à la récupération.

### Cas 2A — User 3 possède déjà un compte Dzokoli

1. Dzokoli recherche un compte vérifié correspondant au numéro fourni.
2. User 3 reçoit une invitation dans l’application.
3. User 3 accepte ou refuse d’être le destinataire.
4. Après acceptation, son identifiant devient `recipientUserId`.
5. Le QR code de récupération est disponible uniquement dans son compte.
6. User 2 peut suivre la livraison, mais ne doit plus pouvoir utiliser le code de User 3.

Ce parcours est le plus sécurisé et doit être privilégié.

### Cas 2B — User 3 ne possède pas encore de compte

Pour une première version, deux stratégies sont possibles.

#### Option recommandée pour le lancement

User 3 doit créer un compte Dzokoli et vérifier son numéro avant de pouvoir récupérer le colis.

Avantages :

- identité et numéro mieux contrôlés ;
- historique de remise conservé ;
- réduction des fraudes ;
- gestion des litiges plus simple.

#### Option future : destinataire invité

User 3 reçoit un lien sécurisé par SMS. Il vérifie son numéro avec un OTP, consulte les informations minimales et obtient un code de récupération sans créer un compte complet.

Cette option facilite l’usage, mais demande davantage de protections contre le partage de lien, le vol de téléphone et l’usurpation d’identité. Elle pourra être ajoutée après stabilisation du parcours principal.

### Remise à destination

1. User 1 signale son arrivée.
2. User 3 reçoit une notification ou un SMS.
3. User 3 présente son QR code et, si nécessaire, une pièce d’identité.
4. User 1 vérifie que le nom affiché correspond à la personne présente.
5. User 1 scanne le QR code.
6. User 3 confirme la réception depuis son téléphone.
7. Dzokoli marque la livraison comme terminée et rend le versement à User 1 éligible.
8. User 2 reçoit également la confirmation de livraison.

## 7. Modification du destinataire

User 2 peut modifier le destinataire uniquement avant le début de la phase de remise à destination.

Règles recommandées :

- modification autorisée tant que le voyageur n’a pas déclaré son arrivée ;
- nouvelle confirmation obligatoire par User 3 ;
- ancien QR code immédiatement invalidé ;
- User 1, User 2 et l’ancien destinataire sont informés du changement ;
- chaque modification est conservée dans un journal d’audit ;
- après l’arrivée, le changement nécessite l’accord de User 1 ou du support Dzokoli.

## 8. Paiement sécurisé et doubles confirmations

Le paiement repose sur deux confirmations distinctes afin de prouver la prise en charge puis la livraison.

### Flux recommandé

1. Lors de la réservation, Dzokoli vérifie le moyen de paiement de User 2 ou effectue une préautorisation lorsque le prestataire de paiement le permet.
2. User 2 fait livrer le colis au domicile de User 1.
3. User 1 prend les photos obligatoires de l’état du colis.
4. User 1 scanne le QR code de prise en charge de User 2.
5. Ce premier scan déclenche le débit de User 2 et place le montant en attente sécurisée.
6. User 1 transporte le colis.
7. À destination, User 1 scanne le QR code du destinataire autorisé.
8. Ce second scan confirme la livraison et termine la mission.
9. La commission Dzokoli est déduite.
10. Le solde est versé au portefeuille de User 1 selon le délai qui sera défini ultérieurement.

En cas d’absence de confirmation, un délai et une procédure de litige devront être définis avant toute libération automatique.

## 9. Statuts recommandés

### Statuts de la réservation

- `pendingPayment` : paiement en attente ;
- `paymentMethodVerified` : moyen de paiement vérifié ou montant préautorisé ;
- `paid` : User 2 a été débité après le premier scan QR ;
- `confirmed` : réservation acceptée automatiquement ;
- `cancelled` : réservation annulée ;
- `cancellationPendingReturn` : annulation demandée, restitution du colis en attente ;
- `cancelledBeforePickup` : annulation terminée avant la prise en charge ;
- `cancelledAfterReturn` : annulation terminée après restitution du colis ;
- `refunded` : paiement remboursé.

### Statuts du colis

- `awaitingDropOff` : le voyageur n’a pas encore reçu le colis ;
- `photosRequired` : les photos de l’état du colis doivent être prises ;
- `receivedByTraveler` : colis remis au voyageur ;
- `inTransit` : voyage commencé ;
- `arrived` : voyageur arrivé ;
- `readyForPickup` : colis prêt à être récupéré ;
- `delivered` : colis remis au destinataire ;
- `disputed` : livraison contestée.

### Statuts du destinataire tiers

- `notRequired` : User 2 récupère lui-même le colis ;
- `invited` : invitation envoyée à User 3 ;
- `accepted` : User 3 a accepté ;
- `declined` : User 3 a refusé ;
- `replaced` : le destinataire a été remplacé.

## 10. Données principales à prévoir

### `Listing`

- `id`
- `travelerId`
- `departure`
- `arrival`
- `departureDate`
- `totalAvailableKg`
- `remainingKg`
- `pricePerKg`
- `acceptedParcelTypes`
- `status`
- `closedAt`
- `closedBy` : `traveler`, `capacityReached` ou `system`

### `Booking`

- `id`
- `listingId`
- `buyerId`
- `reservedKg`
- `pricePerKg`
- `totalAmount`
- `paymentStatus`
- `bookingStatus`

### `Shipment`

- `id`
- `bookingId`
- `description`
- `declaredContents`
- `parcelType`
- `shipmentStatus`
- `dropOffCode`
- `deliveryCode`
- `cancellationCode`
- `pickupConfirmedAt`
- `returnedAt`
- `deliveredAt`

### `Cancellation`

- `id`
- `bookingId`
- `requestedByUserId`
- `reason`
- `requiresParcelReturn`
- `status` : `requested`, `awaitingReturn`, `returned`, `refunded`, `cancelled` ou `disputed`
- `requestedAt`
- `returnConfirmedAt`
- `refundTransactionId`

### `ParcelEvidence`

- `id`
- `shipmentId`
- `photoUrl`
- `capturedByUserId`
- `capturedAt`
- `stage` : `beforePickup` ou, ultérieurement, une autre étape prévue par le produit

### `Review`

- `id`
- `shipmentId`
- `reviewerId` : User 2
- `reviewedUserId` : User 1
- `rating` : note de 1 à 5
- `comment`
- `createdAt`

### `Recipient`

- `shipmentId`
- `recipientType`
- `recipientUserId` facultatif tant que l’invitation n’est pas acceptée ;
- `fullName`
- `phoneE164`
- `email`
- `invitationStatus`
- `acceptedAt`

## 11. Règles de sécurité indispensables

- le QR code ne doit pas contenir directement les informations personnelles ;
- les codes doivent être aléatoires, temporaires et utilisables une seule fois ;
- toute tentative de validation doit être journalisée ;
- User 1 ne voit que les informations nécessaires à la remise ;
- le destinataire ne voit pas les données privées du voyageur ;
- un code remplacé ou utilisé devient immédiatement invalide ;
- les changements importants déclenchent une notification aux parties concernées ;
- les photos originales de prise en charge doivent être horodatées et associées à la livraison ;
- le premier et le second QR code sont différents et ne peuvent pas être réutilisés ;
- seul User 2 peut noter User 1 après une livraison réellement terminée ;
- les contenus interdits et règles douanières doivent être acceptés avant paiement ;
- les pièces d’identité et documents KYC doivent être chiffrés et soumis à une politique de conservation.

## 12. Gestion des problèmes

### Le colis n’est pas remis à User 1 à la date prévue

- User 1 et User 2 utilisent la messagerie pour convenir d’une nouvelle date de remise au domicile de User 1 ;
- tant que le premier QR code n’a pas été scanné, User 2 n’est pas débité ;
- User 2 peut annuler sa demande ;
- User 1 peut également annuler cette demande afin de libérer le poids réservé et recevoir une autre demande ;
- la politique concernant d’éventuels frais d’annulation sera définie ultérieurement.

### Le destinataire est absent à l’arrivée

- User 1 signale l’absence dans l’application ;
- User 1 et User 2 utilisent la messagerie pour reprogrammer une nouvelle date de livraison ;
- le paiement reste bloqué ;
- après un délai défini, le support intervient.

### Le code ne fonctionne pas

- vérifier que le bon destinataire est connecté ;
- permettre une régénération sécurisée après authentification ;
- invalider automatiquement l’ancien code ;
- ne jamais autoriser User 1 à terminer seul la livraison sans preuve alternative.

### User 3 refuse l’invitation

- User 2 est notifié ;
- la réservation reste incomplète tant qu’un nouveau destinataire n’est pas désigné ;
- le voyageur ne reçoit pas les informations du destinataire refusé.

### Le colis est contesté

- le paiement reste bloqué ;
- chaque partie fournit photos, messages et justificatifs ;
- le support examine le journal des événements avant décision.

## 13. Décisions proposées pour le MVP

Pour la première version de Dzokoli :

1. User 2 choisit entre récupération personnelle et destinataire tiers.
2. User 3 doit posséder ou créer un compte avec numéro vérifié.
3. User 3 doit accepter explicitement l’invitation.
4. La remise utilise un QR code ou un code à usage unique.
5. Les demandes sont acceptées automatiquement tant que l’annonce est ouverte et dispose du poids demandé.
6. User 1 peut clôturer son annonce pour bloquer les nouvelles demandes.
7. Le colis est livré au domicile de User 1 avant le départ.
8. User 1 photographie obligatoirement l’état du colis avant sa prise en charge.
9. Un premier scan QR confirme la prise en charge et déclenche le débit de User 2.
10. Un second scan QR confirme la livraison au destinataire et termine la mission.
11. Le paiement reste bloqué entre les deux confirmations.
12. User 2 peut noter User 1 après la livraison.
13. Le changement de destinataire est autorisé avant l’arrivée du voyageur.
14. Les destinataires invités sans compte seront étudiés dans une version ultérieure.

## 14. Connexion par numéro de téléphone et OTP

La connexion à Dzokoli se fait avec un numéro de téléphone au format international E.164 et un code à usage unique reçu par SMS.

### Parcours de connexion

1. L’utilisateur sélectionne son pays et saisit son numéro de téléphone.
2. Dzokoli normalise le numéro au format E.164.
3. Un code OTP temporaire est envoyé par SMS.
4. L’utilisateur saisit le code reçu.
5. Si le code est valide, une session est créée.
6. Si le numéro n’est lié à aucun compte, le profil de l’utilisateur est créé avant de poursuivre son inscription.

### Règles de sécurité

- le code OTP expire après une courte durée ;
- un code ne peut être utilisé qu’une seule fois ;
- le nombre de tentatives et de renvois est limité ;
- un délai est imposé avant de pouvoir demander un nouveau code ;
- les tentatives anormales sont journalisées et temporairement bloquées ;
- le numéro vérifié devient l’identifiant principal du compte ;
- un changement de numéro exige une nouvelle vérification OTP ;
- le code OTP ne doit jamais être conservé en clair ni affiché dans les journaux techniques.

## 15. Notation du voyageur après une livraison

Après le second scan QR et le passage de la livraison à l’état `delivered`, User 2 peut évaluer User 1.

### Contenu d’une évaluation

- une note obligatoire de 1 à 5 étoiles ;
- un commentaire facultatif ;
- la date de publication ;
- la livraison concernée.

### Règles fonctionnelles

- seule la personne ayant effectué la réservation peut publier l’évaluation ;
- une seule évaluation est autorisée par livraison ;
- aucune note ne peut être déposée avant la confirmation de livraison ;
- User 2 peut modifier son évaluation pendant une durée qui reste à définir ;
- les évaluations abusives peuvent être signalées au support ;
- la note moyenne et le nombre total de livraisons évaluées apparaissent sur le profil de User 1 et sur ses annonces ;
- une note supprimée par la modération n’entre plus dans la moyenne.

L’affichage doit toujours associer la moyenne au nombre d’avis, par exemple `4,8 · 27 avis`, afin qu’une note obtenue sur une seule livraison ne soit pas trompeuse.

## 16. Portefeuille Dzokoli

Chaque utilisateur possède un portefeuille rattaché à son compte. Le même portefeuille permet de payer une réservation lorsqu’il agit comme expéditeur et de recevoir ses gains lorsqu’il agit comme voyageur.

### Soldes à distinguer

- `availableBalance` : argent disponible pour payer ou retirer ;
- `reservedBalance` : argent réservé pour une demande confirmée, mais pas encore débité ;
- `escrowBalance` : argent débité de User 2 après la prise en charge et conservé sur un compte de cantonnement lié à la réservation jusqu’à la livraison ;
- `pendingBalance` : gains de User 1 en attente de devenir disponibles ;

### Paiement d’une réservation

1. Dzokoli vérifie que User 2 possède un solde suffisant ou un moyen de paiement permettant d’alimenter son portefeuille.
2. Le montant nécessaire est placé dans `reservedBalance` lors de la réservation et ne peut plus être dépensé ailleurs.
3. Si la demande est annulée avant la prise en charge, le montant réservé redevient disponible selon la politique d’annulation.
4. Au premier scan QR, le montant est effectivement débité et transféré dans `escrowBalance`.
5. Au second scan QR, la livraison est terminée et le montant dû à User 1 passe dans `pendingBalance`, après déduction de la commission Dzokoli.
6. À la fin du délai de paiement qui sera défini, le gain passe dans `availableBalance` de User 1.

### Opérations du portefeuille

- consulter les différents soldes ;
- consulter l’historique détaillé des transactions ;
- alimenter le portefeuille avec les moyens de paiement autorisés ;
- payer une réservation ;
- recevoir le paiement d’une livraison ;
- retirer un solde disponible vers un moyen de retrait autorisé ;
- recevoir une notification pour chaque mouvement d’argent ;
- obtenir le détail des commissions et remboursements.

### Données principales

#### `Wallet`

- `id`
- `userId`
- `currency`
- `availableBalance`
- `reservedBalance`
- `pendingBalance`
- `status` : `active`, `restricted` ou `suspended`

#### `WalletTransaction`

- `id`
- `walletId`
- `bookingId` facultatif
- `type` : `topUp`, `reservation`, `release`, `payment`, `earning`, `commission`, `refund` ou `withdrawal`
- `amount`
- `currency`
- `status` : `pending`, `completed`, `failed` ou `cancelled`
- `reference`
- `createdAt`

#### `Escrow`

- `id`
- `bookingId`
- `payerUserId`
- `beneficiaryUserId`
- `amount`
- `currency`
- `status` : `funded`, `held`, `released`, `refunded` ou `disputed`
- `fundedAt`
- `releasedAt`

Les transactions financières doivent être immuables : une correction se fait avec une nouvelle transaction inverse, jamais en modifiant ou supprimant l’opération originale. Le solde affiché doit être calculable à partir du registre des transactions afin de conserver une piste d’audit fiable.

## 17. Annulations, restitution et remboursements

Toutes les annulations prévues dans le parcours actuel sont sans frais. Leur traitement dépend de l’état de prise en charge du colis.

### Annulation avant le premier QR

Le colis n’a pas encore été officiellement remis à User 1 :

1. User 1 ou User 2 demande l’annulation dans l’application.
2. Aucun échange physique n’est nécessaire si User 1 ne possède pas encore le colis.
3. Le montant réservé redevient disponible dans le portefeuille de User 2.
4. Les kilogrammes réservés sont immédiatement remis à disposition dans l’annonce, si celle-ci est encore ouverte.
5. La commande passe à l’état `cancelledBeforePickup`.

### Annulation après le premier QR

User 1 possède déjà le colis et User 2 a été débité :

1. User 1 et User 2 organisent la restitution dans la messagerie.
2. User 1 remet physiquement le colis à User 2.
3. User 2 présente un QR code d’annulation spécifique.
4. User 1 scanne ce QR uniquement après que User 2 a effectivement récupéré son colis.
5. Le scan confirme la restitution et annule la commande.
6. Le montant placé en séquestre est intégralement remboursé à User 2, sans frais.
7. Les kilogrammes concernés sont remis à disposition si l’annonce est toujours ouverte et si le voyage n’a pas encore commencé.
8. La commande passe à l’état `cancelledAfterReturn`.

Le QR d’annulation doit être différent des QR de prise en charge et de livraison. Il est temporaire, à usage unique et ne devient disponible que lorsqu’une annulation après prise en charge est ouverte.

### Cas où la restitution est contestée

Si une partie affirme que le colis n’a pas été rendu ou qu’il a été rendu endommagé, l’annulation passe à l’état `disputed`. Le remboursement reste bloqué jusqu’à la décision du support sur la base des photos, scans et conversations.

## 18. Modification ou annulation du voyage

### Retard, changement de date ou changement de vol

- User 1 informe User 2 depuis la livraison concernée ;
- une notification est envoyée à User 2 ;
- les deux utilisateurs conviennent de la suite dans la messagerie intégrée ;
- les nouvelles informations du voyage sont enregistrées dans l’application ;
- la commande reste active si User 2 accepte la nouvelle organisation ;
- si aucun accord n’est trouvé, la restitution et l’annulation suivent le parcours correspondant à l’état du colis.

### Changement de destination

Un changement de destination rend la commande incompatible avec la réservation initiale :

1. la commande doit être annulée ;
2. si User 1 possède le colis, il doit le restituer à User 2 avec le QR d’annulation ;
3. User 2 est remboursé sans frais après confirmation de la restitution ;
4. les kilogrammes sont libérés lorsque cela reste pertinent pour l’annonce.

### Planification des remises et restitutions

Les utilisateurs conviennent des dates, heures et modalités dans la messagerie intégrée. L’application doit permettre de proposer un rendez-vous, de l’accepter, de le refuser ou de proposer un autre créneau. Une fois accepté, le rendez-vous est enregistré sur la livraison et génère des rappels.

## 19. Notifications

Dzokoli envoie une notification dans l’application et, selon les préférences disponibles, une notification push pour :

- une nouvelle réservation acceptée automatiquement ;
- un colis à récupérer ou à restituer ;
- un rendez-vous prochain ;
- une proposition ou une modification de rendez-vous ;
- une modification du voyage ;
- la validation du premier QR ;
- la validation du second QR ;
- la validation du QR d’annulation ;
- un paiement, un remboursement ou un versement ;
- un nouveau message ;
- l’ouverture ou la résolution d’un litige.

Chaque notification possède un état lu ou non lu et redirige vers la réservation, la conversation ou la transaction concernée.

## 20. Gestion des capacités

- plusieurs utilisateurs ne peuvent pas réserver simultanément les mêmes kilogrammes ;
- le contrôle et la diminution de `remainingKg` doivent être atomiques côté serveur ;
- le poids demandé est temporairement bloqué pendant le paiement ;
- ce blocage expire automatiquement si le paiement n’aboutit pas dans le délai autorisé ;
- les kilogrammes sont remis à disposition après expiration ou annulation lorsque l’annonce est encore ouverte ;
- l’annonce est automatiquement clôturée lorsque `remainingKg` atteint zéro ;
- une annonce clôturée manuellement ne reçoit plus de demande, même si des kilogrammes sont ensuite libérés ;
- les réservations déjà confirmées restent actives après la clôture de l’annonce.

## 21. Preuves et litiges

### Preuves conservées

- photos horodatées du colis avant sa prise en charge ;
- confirmations du premier QR, du second QR et du QR d’annulation ;
- identité du compte ayant réalisé chaque action ;
- historique complet des changements de statut ;
- conversations liées à la livraison ;
- preuves de paiement, de remboursement et de versement ;
- dates des rendez-vous proposés et acceptés.

Ces éléments sont accessibles au support en cas de litige et doivent respecter la politique de conservation des données qui sera définie ultérieurement.

### Procédure de litige

Un litige peut notamment concerner un colis endommagé, incomplet, non livré ou non restitué :

1. une partie ouvre le litige depuis la commande ;
2. le paiement ou remboursement concerné est automatiquement bloqué ;
3. User 1 et User 2 transmettent leurs explications et leurs preuves ;
4. le support consulte les photos, QR, statuts et conversations ;
5. le support décide d’un versement, d’un remboursement total, d’un remboursement partiel ou d’un rejet ;
6. la décision et les mouvements financiers correspondants sont journalisés.

## 22. Informations visibles et détail des commandes

### Profil du voyageur

- note moyenne ;
- nombre d’avis ;
- nombre de livraisons terminées ;
- taux d’annulation ;
- ancienneté sur Dzokoli ;
- liste des avis reçus.

### Détail d’une commande

- nombre de colis ;
- poids réservé et poids réel ;
- dimensions ;
- description ;
- valeur déclarée ;
- photos avant la prise en charge ;
- statut et chronologie de la livraison ;
- destinataire autorisé.

### Tarification transparente

Avant toute confirmation, User 2 voit :

- le prix des kilogrammes ;
- la commission Dzokoli ;
- les éventuels frais de paiement ;
- le total qui sera payé ;
- les conditions d’annulation applicables.

User 1 voit séparément le montant brut, la commission Dzokoli et le montant net qu’il recevra.

## 23. Favoris et recherches enregistrées

Un utilisateur peut :

- ajouter ou retirer une annonce de ses favoris ;
- enregistrer un trajet et ses filtres de recherche ;
- activer ou désactiver les alertes associées ;
- recevoir une notification lorsqu’une nouvelle annonce correspond à la recherche enregistrée.

Une annonce clôturée ou expirée reste identifiable dans les favoris, mais elle ne peut plus être réservée.

## 24. Solution de secours pour les QR codes

- chaque QR possède également un code numérique temporaire à usage unique ;
- l’utilisateur autorisé peut régénérer le code après une authentification sécurisée ;
- la régénération invalide immédiatement le code précédent ;
- l’application doit prévoir une reprise lorsque la connexion internet est instable, sans permettre une double validation ;
- une validation manuelle exceptionnelle peut être réalisée par le support après vérification des preuves ;
- toute validation manuelle est motivée, horodatée et enregistrée dans le journal d’audit.

## 25. Gestion du compte

Chaque utilisateur peut :

- consulter et modifier les informations autorisées de son profil ;
- changer son numéro après vérification de l’ancien numéro ou procédure de récupération, puis validation OTP du nouveau ;
- consulter ses sessions actives et déconnecter les autres appareils ;
- configurer ses préférences de notifications ;
- demander la désactivation ou la suppression de son compte.

La suppression ne doit pas effacer les informations qui doivent rester conservées pour une livraison active, une transaction, un litige ou une obligation légale. Un compte impliqué dans une opération en cours doit d’abord terminer ou résoudre cette opération.

## 26. Questions restant à décider

- Après combien de temps le paiement peut-il être libéré automatiquement ?
- Quelle assurance couvre le colis et jusqu’à quel montant ?
- Quels documents KYC sont obligatoires pour chaque rôle ?
- Quels pays, catégories de produits et trajets seront autorisés au lancement ?
- Quels moyens permettront d’alimenter et de retirer l’argent du portefeuille ?
- Dzokoli utilisera-t-il une devise unique ou plusieurs devises ?
- Pendant combien de temps User 2 pourra-t-il modifier son évaluation ?

## 27. Décisions d’architecture fonctionnelle confirmées

Cette section conserve les orientations confirmées pour la construction du backend. Elles pourront être précisées pendant la conception du modèle de données et du diagramme de classes.

### Périmètre du backend

- le backend a vocation à couvrir l’ensemble du MVP décrit dans ce guide ;
- le périmètre pourra être réduit ou étendu selon les contraintes et les besoins découverts pendant le développement ;
- les règles fonctionnelles seront harmonisées dans ce projet avant ou pendant la construction du diagramme de classes.

### Gestion des états

Les états actuellement évoqués dans le guide servent de base fonctionnelle. Une machine à états complète et cohérente sera définie dans le backend.

Afin d’éviter de mélanger plusieurs réalités dans un même statut, les états seront séparés par domaine lorsque cela est pertinent :

- état commercial de la réservation ;
- état du paiement et du séquestre ;
- état logistique du colis ;
- état de l’invitation du destinataire ;
- état de l’annulation ou du litige.

Les transitions autorisées, les acteurs habilités, les préconditions et les effets de chaque transition devront être explicitement définis.

### Portefeuille et paiements simulés

- chaque utilisateur disposera d’un portefeuille Dzokoli ;
- l’utilisateur devra alimenter son portefeuille afin de payer une réservation ;
- le choix des partenaires de paiement et de retrait n’est pas encore arrêté ;
- pendant le développement et les tests, les recharges du portefeuille seront simulées ;
- une recharge simulée devra créer une opération traçable dans le registre des transactions, comme le ferait ultérieurement une recharge réelle ;
- l’intégration future d’un prestataire ne devra pas modifier les règles métier du portefeuille, des réservations et du séquestre ;
- le registre immuable des transactions constituera la source d’audit des mouvements financiers ;
- le séquestre lié à une réservation devra être distingué du solde personnel disponible de l’utilisateur.

Le choix entre une devise unique et plusieurs devises reste à décider. Les données financières devront néanmoins toujours enregistrer explicitement leur devise.

### Pays et zones disponibles

Les pays pris en charge ne seront pas inscrits en dur dans l’application. Ils seront gérés dans une table afin de pouvoir :

- activer ou désactiver progressivement des pays ;
- faire évoluer les zones couvertes sans modifier le code métier principal ;
- rattacher ultérieurement des règles, devises ou contraintes propres à chaque pays.

La liste exacte des pays disponibles au lancement reste à déterminer.

### Questions juridiques

La responsabilité juridique du transport entre le voyageur, Dzokoli et un éventuel partenaire agréé n’est pas encore décidée. Les règles relatives à l’assurance, aux obligations réglementaires, aux produits interdits et aux limites de responsabilité devront être validées avant une mise en production réelle.
