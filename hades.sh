#!/bin/bash

COLS=$(tput cols)
ROWS=$(tput lines)

# ====================================================================================================================================================================================
# base 安装基本环境
# ====================================================================================================================================================================================
install_base() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] base\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    install_software update
    install_software upgrade

    install_software install epel-release
    install_software install git
    install_software install curl
    install_software install vim
    install_software install net-tools

    mkdir -p /data /data/cron /data/web

    timedatectl set-timezone Asia/Shanghai

    setenforce 0
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" "/etc/selinux/config"

    systemctl stop firewalld
    systemctl mask firewalld

    echo "[info] setup base finished. \n"
}

# ====================================================================================================================================================================================
# swap 安装基本环境
# ====================================================================================================================================================================================
install_swap() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] swap\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    # mkdir -p /opt/swap
    # if [ ! -f "/opt/swap/swapfile" ]; then
    #     dd if=/dev/zero of=/opt/swap/swapfile bs=1024 count=1024000
    #     mkswap /opt/swap/swapfile

    #     chmod 600 /opt/swap/swapfile

    #     swapon /opt/swap/swapfile
    #     echo "/opt/swap/swapfile swap swap defaults 0 0" >>/etc/fstab
    # else
    #     swapon /opt/swap/swapfile
    # fi

    echo "[info] setup swap finished. \n"
}

# ====================================================================================================================================================================================
# nginx
# ====================================================================================================================================================================================
install_nginx() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] nginx\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    install_software install nginx

    for i in ${!DOMAIN_NAME[@]}; do
        rm -rf /etc/nginx/conf.d/${DOMAIN_NAME[$i]}.conf
    done
    systemctl restart nginx
    systemctl enable nginx

    echo "[info] setup nginx finished. \n"
}

# ====================================================================================================================================================================================
# dns
# ====================================================================================================================================================================================
install_dns() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] domain dns\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    CFTTL=120
    PROXIED=false

    for i in ${!DOMAIN_NAME[@]}; do
        if [ ${DOMAIN_CDNS[$i]} != false ]; then
            echo "[info] skip cdn domain " ${DOMAIN_NAME[$i]}
            continue
        fi

        ID_FILE=~/.cf-id_${DOMAIN_NAME[$i]}.txt
        echo "[info] updating zone_identifier & record_identifier"
        CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN_ZONE" -H "Authorization: Bearer $CFAPI_KEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
        CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=${DOMAIN_NAME[$i]}" -H "Authorization: Bearer $CFAPI_KEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
        echo "$CFZONE_ID" >$ID_FILE
        echo "$CFRECORD_ID" >>$ID_FILE
        echo "$DOMAIN_ZONE" >>$ID_FILE
        echo "${DOMAIN_NAME[$i]}" >>$ID_FILE

        if [ "$CFRECORD_ID"x != x ]; then
            echo "[info] update dns record. "
            RESPONSE=$(
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
                    -H "Authorization: Bearer $CFAPI_KEY" \
                    -H "Content-Type: application/json" \
                    --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"${DOMAIN_NAME[$i]}\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL, \"proxied\":$PROXIED}"
            )
            echo "response: $RESPONSE"
        else
            echo "[info] create dns record. "
            RESPONSE=$(
                curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" \
                    -H "Authorization: Bearer $CFAPI_KEY" \
                    -H "Content-Type: application/json" \
                    --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"${DOMAIN_NAME[$i]}\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL, \"proxied\":$PROXIED}"
            )
            echo "response: $RESPONSE"
        fi
    done

    echo "[info] setup domain dns finished. \n"
}

# ====================================================================================================================================================================================
# certbot
# ====================================================================================================================================================================================
install_cert() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] certbot\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    install_software install snapd

    if [ ${PACKAGE_MANAGEMENT} = "yum" ]; then
        systemctl enable --now snapd.socket
        ln -s /var/lib/snapd/snap /snap

        snap wait system seed.loaded
        snap install --classic certbot
    fi

    if [ ${PACKAGE_MANAGEMENT} = "apt" ]; then
        snap install core
        snap refresh core

        snap wait system seed.loaded
        snap install --classic certbot
    fi

    ln -s /snap/bin/certbot /usr/bin/certbot

    echo "[info] setup certbot finished. \n"
}

# ====================================================================================================================================================================================
# config
# ====================================================================================================================================================================================
install_conf() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] config\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    for i in ${!DOMAIN_NAME[@]}; do
        if [ ${DOMAIN_CDNS[$i]} != false ]; then
            echo "[info] skip cdn domain " ${DOMAIN_NAME[$i]}
            continue
        fi

        SUCCESS=false
        WAITTIME=60
        echo "[info] cert for domain " ${DOMAIN_NAME[$i]}
        while [ ${SUCCESS} = false ]; do
            certbot certonly \
                --nginx -n --agree-tos -w /data/web \
                --email ${DOMAIN_MAIL} \
                -d ${DOMAIN_NAME[$i]}

            if [ $? -ne 0 ]; then
                SUCCESS=false
                echo "[info] cert failed. "
                echo "[info] wait for dns. "
                for ((time = ${WAITTIME}; time > 0; time--)); do
                    min=$(($time / 60))
                    sec=$(($time % 60))
                    echo -ne "\r[info] wait ${min} min ${sec} sec \r"
                    sleep 1
                done
                echo
            else
                SUCCESS=true
                WAITTIME=0
                echo "[info] cert successed. "
            fi
        done

        echo /etc/nginx/conf.d/${DOMAIN_NAME[$i]}.conf
        cat >/etc/nginx/conf.d/${DOMAIN_NAME[$i]}.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 http2;
    ssl_certificate         /etc/letsencrypt/live/${DOMAIN_NAME[$i]}/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/${DOMAIN_NAME[$i]}/privkey.pem;
    ssl_protocols         TLSv1.1 TLSv1.2;
    ssl_ciphers           TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES-128-GCM-SHA256:TLS13-AES-128-CCM-8-SHA256:TLS13-AES-128-CCM-SHA256:EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
    server_name           ${DOMAIN_NAME[$i]};
    index index.html index.htm;
    root  /data/web;
    error_page 400 = /400.html;
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=31536000";
    location /
    {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${DOCKER_PORT[$i]};
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }
}
EOF
    done

    # 添加CDN节点nginx配置文件
    for i in ${!DOMAIN_NAME[@]}; do
        if [ -z "${DOMAIN_CDNS[$i]}" ]; then
            echo "[info] skip normal domain " ${DOMAIN_NAME[$i]}
            continue
        fi
        echo /etc/nginx/conf.d/${DOMAIN_NAME[$i]}.conf
        cat >/etc/nginx/conf.d/${DOMAIN_NAME[$i]}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name             ${DOMAIN_NAME[$i]};
    index                   index.html index.htm;
    root                    /data/web;
    error_page 400 =        /400.html;
    location /
    {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${DOCKER_PORT[$i]};
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }
}
EOF
    done

    echo "[info] setup nginx config finished. \n"
}

# ====================================================================================================================================================================================
# crontab
# ====================================================================================================================================================================================
install_cron() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] crontab\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    crontab -l >crontabfile
    CRON_INFO="0 5 * * * certbot renew >> /data/cron/cron.log"

    if [ $(grep -c -F "${CRON_INFO}" crontabfile) -ne '0' ]; then
        echo "[info] cron already exist , skip"
    else
        echo "${CRON_INFO}" >>crontabfile && crontab crontabfile && rm -f crontabfile
        echo "[info] cron added"
    fi

    echo "[info] setup crontab finished. \n"
}

# ====================================================================================================================================================================================
# docker
# ====================================================================================================================================================================================
install_docker() {
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    printf "[step] docker\n"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    docker version >/dev/null || curl -fsSL get.docker.com | bash

    if ! type docker >/dev/null 2>&1; then
        echo '[error] docker not found !'
        exit 1
    fi

    service docker restart
    systemctl enable docker

    for i in ${!DOMAIN_NAME[@]}; do
        docker run \
            -d --name=${DOCKER_NAME[$i]} \
            -p ${DOCKER_PORT[$i]}:2080 \
            -e nodeID=${DOCKER_NODE[$i]} \
            -e panelUrl=${PANEL_URL} \
            -e customer=${PANEL_CST} \
            -e panelLic=${PANEL_LIC} \
            -e panelKey=${PANEL_KEY} \
            --log-opt max-size=10m \
            --log-opt max-file=5 \
            --restart=always zeva20/hades:latest
        echo
    done

    docker run \
        -d --name watchtower \
        --restart unless-stopped \
        -v /var/run/docker.sock:/var/run/docker.sock \
        containrrr/watchtower -c

    echo "[info] setup docker finished"
}

# ====================================================================================================================================================================================
# output
# ====================================================================================================================================================================================
output_result() {
    printf "\033[1m\033[43;42m%-${COLS}s\033[0m\n" "=" | sed "s/ /=/g"

    for i in ${!DOMAIN_NAME[@]}; do
        if [ ${DOMAIN_CDNS[$i]} != false ]; then
            echo "[info] skip cdn domain " ${DOMAIN_NAME[$i]}
            continue
        fi
        printf "[info] server ${DOCKER_NODE[$i]} config:\n"
        printf "${DOMAIN_NAME[$i]};443;2;tls;ws;path=/|host=${DOMAIN_NAME[$i]}\n"
        printf "\n"
    done

    printf "\033[1m\033[43;42m%-${COLS}s\033[0m\n" "=" | sed "s/ /=/g"

    for i in ${!DOMAIN_NAME[@]}; do
        if [ -z "${DOMAIN_CDNS[$i]}" ]; then
            echo "[info] skip normal domain " ${DOMAIN_NAME[$i]}
            continue
        fi
        printf "[info] server ${DOCKER_NODE[$i]} config:\n"
        printf "${DOMAIN_CDNS[$i]};80;2;;ws;path=/|server=${DOMAIN_CDNS[$i]}|host=${DOMAIN_NAME[$i]}\n"
        printf "\n"

        printf "[info] cdn domain :\n"
        printf "${DOMAIN_NAME[$i]}\n"
        printf "\n"
    done
}

# ====================================================================================================================================================================================
# 显示标题
# ====================================================================================================================================================================================
output_title() {
    if ! type gawk >/dev/null 2>&1; then
        echo '[info] gawk not found'
        install_software install gawk
    else
        echo '[info] gawk installed'
    fi

    # sleep 1
    clear
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    echo "= hades installer"
    echo "= using package management ${PACKAGE_MANAGEMENT}"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    echo

    parameter="安装参数\n"
    parameter=${parameter}"对接面板域名: ${PANEL_URL}\n"
    parameter=${parameter}"\n"
    parameter=${parameter}"ID\tDomain\tCDN\tDOCKER_NAME\tDOCKER_PORT\tDOCKER_NODE\n"
    for i in ${!DOMAIN_NAME[@]}; do
        parameter=${parameter}${i}"\t"${DOMAIN_NAME[$i]}"\t"${DOMAIN_CDNS[$i]}"\t"${DOCKER_NAME[$i]}"\t"${DOCKER_PORT[$i]}"\t"${DOCKER_NODE[$i]}"\n"
    done

    echo -e ${parameter} | sh table.sh -14 -white,-white,-white

    echo "回车确认开始安装"
    read -n 1
}

# ====================================================================================================================================================================================
# 确认操作系统
# ====================================================================================================================================================================================
identify_system() {
    if [[ "$(uname)" == 'Linux' ]]; then
        if [[ ! -f '/etc/os-release' ]]; then
            echo "[error] don't use outdated linux distributions."
            exit 1
        fi
        if [[ "$(type -P apt)" ]]; then
            PACKAGE_MANAGEMENT='apt'
        elif [[ "$(type -P yum)" ]]; then
            PACKAGE_MANAGEMENT='yum'
        else
            echo "[error] the script does not support the package manager in this operating system."
            exit 1
        fi
    else
        echo "[error] this operating system is not supported."
        exit 1
    fi
}

# ====================================================================================================================================================================================
# 确认安装方式
# ====================================================================================================================================================================================
identify_operate() {
    clear
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"
    echo "= hades installer"
    printf "%-${COLS}s\n" "=" | sed "s/ /=/g"

    read -p "对接方式 [auto]-使用脚本默认参数 [other]-手动输入参数 (回车默认使用 auto 模式) :" operation
    if [ -z "${operation}" ]; then
        operation="auto"
    fi

    if [ "${operation}" != "auto" ]; then
        unset DOMAIN_NAME
        unset DOMAIN_CDNS
        unset DOCKER_NAME
        unset DOCKER_PORT
        unset DOCKER_NODE

        while true; do
            read -p "请输入对接后端数量:" count
            if [[ "$count" =~ ^[0-9]+$ ]]; then
                break
            fi
        done
        for ((i = 0; i < ${count}; i++)); do
            echo "第 $i 个节点配置:"
            read -p "请输入节点域名(不包含 http:// ):" DOMAIN_NAME[$i]
            read -p "请输入CDN节点域名(非CDN请留空):" DOMAIN_CDNS[$i]
            read -p "请输入节点ID:" DOCKER_NODE[$i]
            read -p "请输入节点DOCKER名字:" DOCKER_NAME[$i]
            read -p "请输入节点DOCKER端口:" DOCKER_PORT[$i]
        done
    fi
}

# ====================================================================================================================================================================================
# 安装软件
# ====================================================================================================================================================================================
install_software() {
    package_opt="$1"
    package_name="$2"
    if ${PACKAGE_MANAGEMENT} "-y" "${package_opt}" "${package_name}"; then
        echo "[info] ${package_name} is ${package_opt}ed."
    fi
}
