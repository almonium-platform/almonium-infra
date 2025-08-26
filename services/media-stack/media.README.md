## Core Concepts

The guiding principle of this setup is the **separation of data from the application**. We use Docker to achieve this, following a simple but powerful analogy:

-   **Docker Containers are Temporary Workers:** Think of each application (Traefik, Emby, Syncthing) as a temporary employee hired to do a specific job. They live in a temporary office (the container). If a worker becomes slow or broken, we can instantly fire them (`docker rm`) and hire a brand new, identical replacement (`docker compose up`).

-   **Docker Volumes are Permanent Filing Cabinets:** Your data (audiobooks, movies, application settings) is stored in "permanent filing cabinets" (folders on your host server like `/home/almonium/media/`). We give the temporary workers a key to these cabinets. When a worker is replaced, the new one gets the same key and can access all the data exactly where the old one left off.

> **The applications are disposable; the data is permanent.**

---

## The Cast of Characters (Our Services)

### 1. Traefik: The Smart Receptionist

Traefik acts as the single front door to our entire system. All traffic from the internet first goes to Traefik. Its jobs are:
-   **Routing:** It looks at the incoming address (like `emby.almonium.com`) and directs the visitor to the correct container (the Emby worker).
-   **Security (HTTPS):** It automatically requests and renews SSL certificates from Let's Encrypt, ensuring all connections are secure. It handles all the encryption so the applications behind it don't have to.

### 2. Docker & Docker Compose: The Foundation

-   **Docker** is the technology that allows us to package our applications into the "temporary worker" containers.
-   **Docker Compose** is our instruction manual (`docker-compose.yaml`). It tells Docker exactly which workers to hire, what tools (volumes/configs) to give them, and how they should talk to each other over a private network (`proxy-net`).

### 3. Syncthing: The Automated Delivery Service

Syncthing is our personal, private, and secure Dropbox. Its only job is to be the delivery person between your local PC and the server.
-   It watches a folder on your PC (e.g., `D:\Emby`).
-   When a new file appears, it securely transfers it and places it directly into one of our "permanent filing cabinets" on the server (e.g., `/home/almonium/media/audiobooks`).

### 4. Emby: The Librarian and Cinema

Emby is the end-user application that makes your media beautiful and accessible.
-   It constantly watches the "permanent filing cabinets" (`/home/almonium/media/`).
-   When Syncthing delivers a new file, Emby automatically scans it, downloads artwork and information, and adds it to your library.
-   It provides a web interface (and apps) for you to browse and play your media from anywhere.

### 5. GitHub Actions: The Automated Deployment Robot

This is our CI/CD (Continuous Integration/Continuous Deployment) system. It watches this Git repository for changes.
-   When you `git push` a change to a `docker-compose.yaml` file, the robot automatically connects to the server.
-   It runs `git pull` to get the latest instruction manual.
-   It runs `docker compose up -d` to hire, fire, and update the "workers" according to the new instructions.

---

## The Workflow: An Audiobook's Journey

Here is how it all works together, from your PC to your screen:

1.  **You:** Drop a new file, `My-Awesome-Audiobook.mp3`, into your `D:\Emby\` folder.
2.  **Syncthing (on your PC):** Instantly detects the new file and starts sending it to the server.
3.  **Syncthing (on the server):** Receives the file and saves it to the permanent location: `/home/almonium/media/audiobooks/My-Awesome-Audiobook.mp3`.
4.  **Emby (on the server):** Sees a new file appear in the folder it's monitoring. It scans the file, identifies it, and adds it to the library.
5.  **You:** Open a browser and go to `https://emby.almonium.com`.
6.  **Traefik (on the server):** Intercepts your request, checks that it's secure, and forwards you to the Emby container's web page.
7.  **You:** See "My Awesome Audiobook" in your library and press play.

## How to Manage This System

-   **To Add New Media:** Simply drop files into your synced folder on your local PC. That's it. The rest is automatic.
-   **To Update or Change a Service:** Edit the appropriate `docker-compose.yaml` file in this repository and `git push`. The robot will handle the rest.
