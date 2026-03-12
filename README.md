# s-ui configuration
1.clone this repository by using command: git clone xxxx
2.enter the repository directory
3.edit the config.sh file
4.execute: chmod +x ./deploy_all.sh
5.run deploy_all.sh
6.switch to the user you configured in step 3
7.run docker compose up -d
8.run docker exec -it tailscale tailscale up, to finish the registration