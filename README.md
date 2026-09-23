# bloc5_pokito

## Usine Logicielle (Pipelines CI/CD)

L'ensemble de l'infrastructure et des déploiements applicatifs de Pokito est automatisé via des workflows GitHub Actions. Cette architecture GitOps est conçue pour garantir la haute disponibilité, la sécurité (modèle Zero Trust) et l'optimisation des coûts cloud (FinOps).

### 1. Intégration et Déploiement Continus (`build.yml`)
**Déclencheur :** Automatique à chaque `push` sur la branche `main`.  
**Rôle :** Pipeline unifié gérant le cycle de vie complet de l'application, de la compilation du code jusqu'au déploiement en production.

* **Authentification Secretless (OIDC) :** Le pipeline s'authentifie auprès d'AWS via des jetons temporaires, respectant le principe du moindre privilège (aucune clé statique stockée).
* **Artéfacts Immuables (CI) :** Construction de l'image Docker de Pokito et publication sur le registre GitHub (GHCR). L'image reçoit un tag dynamique unique (`v1.${github.run_number}`) pour éliminer le pattern risqué du tag `latest` et garantir la traçabilité.
* **Déploiement "Zero SSH" (CD) :** L'outil Ansible se connecte aux instances EC2 de manière chiffrée et transparente via l'agent **AWS Systems Manager (SSM)**. L'orchestrateur Docker Swarm déploie ensuite la nouvelle version de manière distribuée.

### 2. Rollback Déterministe (`rollback.yml`)
**Déclencheur :** Manuel (via `workflow_dispatch` dans l'interface GitHub).  
**Rôle :** Mécanisme de *Disaster Recovery* permettant de restaurer instantanément une ancienne version stable en cas d'incident en production.

* **Utilisation :** Lors du déclenchement, le workflow invite l'ingénieur à saisir le tag exact de l'image à restaurer (ex: `v1.42`).
* **Mécanique :** Ansible exécute une commande Ad-Hoc ciblée sur le Manager Swarm pour forcer la mise à jour du service avec les accès au registre (`--with-registry-auth`). L'orchestrateur applique un *Rolling Update* inversé, garantissant aucune coupure pour les joueurs pendant la bascule.

### 3. FinOps & Green IT (`destroy.yml`)
**Déclencheur :** Manuel (ou planifiable via Cron).
**Rôle :** Optimisation stricte du budget d'infrastructure (TCO) et réduction de l'empreinte carbone liée aux serveurs.

* **Mécanique :** Exécution automatisée d'un `terraform destroy` ciblé. Il permet d'éteindre et de détruire l'infrastructure durant les heures creuses (nuits et week-ends). L'Infrastructure-as-Code garantit que ces environnements peuvent être recréés à l'identique le lendemain matin, réduisant les coûts d'hébergement.
