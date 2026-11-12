# Fidèle — cartes de fidélité pour restaurants

Version réelle, multi-restaurants. Pages statiques + Supabase (base de données centralisée et comptes du staff). Aucun serveur à maintenir.

```
supabase/schema.sql   la base : tables, sécurité, fonctions (à exécuter une fois)
web/config.js         les 2 réglages à remplir
web/index.html        inscription client      → index.html?r=casa-di-meco
web/carte.html        carte du client + QR    → carte.html?t=<token>
web/scan.html         écran serveur (caméra)
web/admin.html        back-office gérant
```

## Installation (environ 15 minutes)

1. **Créer le projet Supabase** sur supabase.com (offre gratuite, région Europe).
2. **Créer la base** : SQL Editor → nouvelle requête → coller tout `supabase/schema.sql` → Run.
   Casa Di Meco est créé automatiquement (10 tampons = une pizza offerte).
3. **Créer ton compte gérant** : Authentication → Users → ajouter un utilisateur (email + mot de passe, confirmé d'office). Puis dans SQL Editor :
   ```sql
   insert into public.staff (user_id, restaurant_id, role)
   select u.id, r.id, 'gerant'
   from auth.users u, public.restaurants r
   where u.email = 'TON_EMAIL' and r.slug = 'casa-di-meco';
   ```
4. **Fermer les inscriptions libres** : dans les réglages Authentication, désactiver la création de compte par les visiteurs. Seul toi crées les comptes staff.
5. **Remplir `web/config.js`** : URL du projet + clé *publishable* (`sb_publishable_...`), dans les réglages API Keys du projet. Jamais la clé *secret*.
6. **Mettre en ligne le contenu de `web/`** sur GitHub Pages (ou Netlify, etc.). HTTPS obligatoire pour la caméra : GitHub Pages le fournit.
7. **Tester** :
   - `admin.html` → connexion → l'affiche avec le QR d'inscription s'affiche. Imprime-la.
   - Scanne ce QR avec ton iPhone → crée une carte.
   - `scan.html` sur la tablette → « Activer la caméra » → scanne la carte du téléphone. Le tampon apparaît sur le téléphone en quelques secondes.

## Au quotidien

**Ajouter un serveur** : créer son utilisateur (étape 3), avec `'serveur'` à la place de `'gerant'`. Il accède à `scan.html` mais pas au back-office. Un seul compte partagé sur la tablette du resto suffit pour démarrer.

**Ajouter un restaurant** (nouveau client) :
```sql
insert into public.restaurants (slug, name, prefix, goal, reward, color)
values ('le-comptoir', 'Le Comptoir', 'LCP', 8, 'Un dessert offert', '#1F3A5F');
```
Puis créer le compte du gérant et le lier (étape 3 avec le bon slug). Son lien d'inscription : `index.html?r=le-comptoir`.

**Client qui a perdu sa carte** : sur `scan.html`, chercher par prénom ou téléphone → « Réafficher sa carte » → il scanne le QR affiché.

**Supprimer un client** (demande RGPD) :
```sql
delete from public.cards where phone = '0612345678';
```

## Comment la sécurité est faite

- Le client n'a aucun compte. Son QR contient un identifiant secret impossible à deviner ; le compteur de tampons est uniquement dans la base.
- Sans connexion staff, on ne peut que : voir le nom/programme d'un resto, s'inscrire, lire sa propre carte. Impossible d'ajouter un tampon.
- Un compte staff ne voit et ne tamponne que les cartes de ses restaurants.
- Anti double-scan : 1 tampon maximum par minute et par carte.

## Limites actuelles

- **Pas encore de carte Apple Wallet / Google Wallet** : la carte est une page web (à ajouter à l'écran d'accueil). Le passage en Wallet demande un compte Apple Developer (payant) et un compte émetteur Google ; c'est l'étape suivante, la base est déjà prête pour ça.
- **Pas de notifications push** : elles arrivent avec les cartes Wallet.
- **Numéros de téléphone non vérifiés** (pas de SMS de confirmation) et pas d'anti-robot sur l'inscription. Sans conséquence sur les tampons, mais à ajouter avant une diffusion large.
- **Hors ligne** : la tablette a besoin d'internet pour tamponner.
- **RGPD** : tu collectes prénom + téléphone. Prévois une mention d'information sur l'affiche ou la page, et n'utilise pas les numéros pour de la prospection sans consentement explicite.
