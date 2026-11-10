Travail de Maxime Girard : reverse proxy, bind mounts et alertes

Ce que j'ai fait

Ma partie consistait à mettre en place Traefik comme unique porte d'entrée de l'infrastructure. Traefik n'expose en effet que le port 80 : c'est le seul conteneur qui publie un port sur la machine hôte, et tout le trafic passe obligatoirement par lui avant d'atteindre les autres services. J'aime bien (et c'est comme ça que j'ai retenu) comme l'accueil d'une entreprise, c'est le seul endroit qui est ouvert.

J'ai ensuite configuré les routes qui permettent d'accéder au site, à l'API, à Grafana, à Prometheus, à Mailpit, à Alertmanager ainsi qu'au tableau de bord de Traefik lui-même. (et déjà tout ça c'est déjà pas mal...) Même si ce n'était pas demandé dans la consigne, cela montre que Traefik est fonctionnel au moins, et ça m'a montré comment faire, c'est pas aussi compliqué que je le pensais.

Je me suis aussi occupé des bind mounts, c'est-à-dire du montage des fichiers de configuration de Traefik et de nginx ainsi que de la page web, directement depuis le dépôt vers les conteneurs. Enfin, j'ai mis en place un système d'alerte qui envoie un mail dès qu'un service tombe.

Pour m'assurer que tout fonctionnait réellement, j'ai terminé par un test complet à partir d'un clone vide du dépôt, afin de vérifier que le projet démarre sans dépendre de fichiers présents uniquement sur ma machine.

Accéder aux services

Une fois la stack lancée, voilà la liste des applications et interfaces disponibles :

- L'application : http://helpdesk.localhost
- Le tableau de bord de Traefik : http://traefik.localhost/dashboard/
- Les outils de supervision : http://grafana.localhost, http://prometheus.localhost et http://alertmanager.localhost
- Mailpit : http://mail.localhost

Pourquoi j'ai choisi Traefik

J'ai choisi Traefik d'abord parce que c'était celui que je connaissais le mieux et le plus adapté par rapport aux technos utilisées par mes camarades, mais également parce qu'il a été pensé dès le départ pour fonctionner avec des conteneurs. Il intègre un healthcheck et expose nativement des métriques au format Prometheus, ce qui s'intégrait parfaitement à notre supervision sans ajouter d'outil supplémentaire, ce qui aurait pu être faisable (et qui d'ailleurs était le cas dans notre ancien projet) mais qui était beaucoup trop long pour la refonte en 1 jour du projet.

J'ai envisagé nginx, mais il aurait demandé d'écrire toute la configuration à la main et ne fournit pas de métriques exploitables directement par Prometheus.

Pourquoi les routes sont définies dans un fichier

Traefik est souvent utilisé en lui donnant accès au socket Docker, ce qui lui permet de découvrir les conteneurs tout seul. J'ai volontairement refusé cette approche, car donner accès au socket Docker revient à donner les droits root sur la machine hôte. Si Traefik était compromis, l'attaquant pourrait alors contrôler tout le système, et on sait que dans tous les cas avec ce super support de cours ! ( +10 points ? ) on ne doit pas faire cela.

J'ai donc séparé la configuration en deux fichiers. Le fichier traefik.yml contient la configuration de démarrage, comme les points d'entrée et l'activation des métriques, tandis que le fichier dynamic.yml contient uniquement les routes vers les différents services. Traefik surveille ce second fichier et applique en principe les changements dès qu'il est modifié.

Les bind mounts

Les fichiers traefik.yml, dynamic.yml, nginx.conf et index.html sont montés depuis le dépôt directement dans les conteneurs. Cela permet de modifier la configuration ou la page web sans avoir à reconstruire d'image.

Tous ces montages utilisent l'option :ro, qui les rend accessibles en lecture seule. Un conteneur peut donc lire sa configuration mais ne peut en aucun cas la modifier, ce qui limite les dégâts possibles en cas de compromission. J'ai également ajouté l'option :z, qui applique la bonne étiquette SELinux aux fichiers. Sans elle, SELinux bloque l'accès aux fichiers montés sur les distributions comme Fedora (meilleur OS je veux rien savoir pour jouer et utiliser linux).

La sécurisation de Traefik

Comme Traefik est le seul service exposé, c'est aussi celui qui est le plus susceptible d'être attaqué. J'ai donc cherché à réduire au maximum ce qu'il peut faire. Il tourne avec l'utilisateur nobody (UID 65534) au lieu de root, ce qui signifie qu'une faille dans Traefik ne donnerait pas de privilèges élevés dans le conteneur.

Il a aussi d'autres protections :

- read_only : il ne peut rien écrire sur son disque
- cap_drop: ALL : on lui retire tous les droits spéciaux de root
- no-new-privileges : il ne peut pas récupérer de droits en plus pendant qu'il tourne
- mem_limit: 128m et pids_limit: 100 : il ne peut pas prendre toute la mémoire ni lancer trop de processus
- image épinglée par son sha256 : c'est toujours exactement la même image, elle ne peut pas changer dans notre dos

Les alertes

J'ai écrit une règle Prometheus appelée ServiceDown, qui se déclenche lorsqu'un service ne répond plus pendant une minute entière, c'est-à-dire lorsque la métrique up vaut 0. Ce délai évite de déclencher une alerte pour une simple coupure de quelques secondes. Quand l'alerte se déclenche, Prometheus la transmet à Alertmanager, qui envoie un mail dans Mailpit. Lorsque le service redémarre, un second mail marqué RESOLVED est envoyé pour signaler que tout est rentré dans l'ordre.

Pour tester ce fonctionnement, il suffit d'arrêter volontairement l'API avec la commande docker compose stop api, d'attendre environ une minute puis d'ouvrir http://mail.localhost, où le mail d'alerte doit apparaître. En relançant l'API avec docker compose start api, le mail RESOLVED arrive peu après.

Les difficultés rencontrées

Au premier lancement, nginx renvoyait une erreur 403 au lieu d'afficher la page. En cherchant, j'ai compris que le fichier index.html avait été créé sans droit de lecture pour les autres utilisateurs. Or nginx tourne dans le conteneur avec un utilisateur qui n'est pas le propriétaire du fichier, il n'avait donc tout simplement pas le droit de le lire.

J'ai rencontré un problème très proche avec Postgres, qui plantait au démarrage avec une erreur qui était « Permission denied » sur le dossier des scripts d'initialisation (db/init). Là encore, les dossiers n'avaient pas le droit de lecture et de traversée pour l'utilisateur postgres du conteneur.

Ces deux problèmes avaient en réalité la même cause : ma machine utilise un umask strict, ce qui fait que les fichiers que je crée n'ont par défaut aucun droit de lecture pour les autres utilisateurs. Je les ai résolus en redonnant les droits de lecture nécessaires aux fichiers avec chmod, et les droits de lecture et de traversée aux dossiers.

Sous Fedora, j'ai aussi été bloqué par SELinux, qui refusait l'accès des conteneurs aux fichiers montés même lorsque les permissions classiques étaient correctes. J'ai réglé le problème en ajoutant l'option :z aux bind mounts et, pour les dossiers concernés, en leur attribuant l'étiquette container_file_t avec la commande chcon.

Enfin, au moment de fusionner mon travail avec la branche de Luka, nous avons eu un conflit sur le fichier compose.yml, puisque nous l'avions modifié tous les deux. Je l'ai résolu à la main en conservant à la fois ses services et les miens, puis j'ai relancé la stack pour vérifier que tout fonctionnait encore après la fusion. J'étais plus celui qui attendait les modifications de mes camarades et qui s'adaptait que celui qui faisait et laissait les autres s'adapter. C'est aussi ce qui a orienté, tout au long de l'exercice, mes choix de technos.

Sous Fedora (SELinux)

Avant le premier lancement :

chcon -R -t container_file_t secrets db backup prometheus grafana alertmanager

Les améliorations possibles

Plusieurs pistes permettraient d'aller plus loin. La première serait de passer en HTTPS. Il serait aussi pertinent de protéger les tableaux de bord par un mot de passe grâce au middleware basicAuth de Traefik, car ils sont actuellement accessibles à n'importe qui ayant accès au réseau. Enfin, il serait utile d'ajouter d'autres règles d'alerte, par exemple sur l'espace disque ou la consommation mémoire, afin de détecter les problèmes avant qu'ils ne provoquent l'arrêt d'un service.

Mon ressenti

Étant donné que nous avions décidé, le jour même, de recommencer notre projet à zéro pour qu'il ne soit pas fait qu'à l'IA, histoire d'ajouter une plus-value, nous avons réussi en un temps limité à comprendre ce que nous avons vu en cours (en partie, pas tout évidemment). Pour ma part, j'ai surtout pu appliquer plus concrètement ce que l'on a vu. Évidemment, cela reste selon moi des connaissances fragiles, à améliorer par la suite, plus qu'une possible évolution de notre application. Je pense réutiliser Docker à l'avenir : sans la pression de la notation et avec des outils comme l'IA, cela me permettra sans doute de faire plusieurs projets sympas.
