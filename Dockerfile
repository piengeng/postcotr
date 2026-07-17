FROM alpine:3.24.1

ARG PKGS="valkey postfix postfix-ldap dovecot dovecot-ldap dovecot-lmtpd wireguard-tools rspamd clamav freshclam ca-certificates"
ARG PKGS_1="iproute2-ss curl dua ripgrep bat nginx"
# RUN apk update # for apk search afterward
# RUN apk add --no-cache $PKGS
RUN apk add $PKGS $PKGS_1
# s6-overlay
ARG S6_VER=3.2.3.0
ARG GH_S6=https://github.com/just-containers/s6-overlay/releases/download/v${S6_VER}
ARG GH_S6_1=${GH_S6}/s6-overlay-noarch.tar.xz
ARG GH_S6_2=${GH_S6}/s6-overlay-x86_64.tar.xz
# non-builtin exporters rspamd(11334) dovecot(9900) clamav(9906) postfix/mtail(3903) redis(9121)
ARG GH_MT=https://github.com/google/mtail/releases/download/v3.0.8/mtail_3.0.8_linux_amd64.tar.gz
arg GH_MT_1=https://raw.githubusercontent.com/google/mtail/v3.0.8/examples/postfix.mtail
ARG GH_CL=https://github.com/sergeymakinen/clamav_exporter/releases/download/v2.1.3/clamav_exporter_2.1.3_linux_amd64.tar.gz
ARG GH_RE=https://github.com/oliver006/redis_exporter/releases/download/v1.86.0/redis_exporter-v1.86.0.linux-amd64.tar.gz
# ADD $GH_S6_1 $GH_S6_2 $GH_MT /tmp # not keeping in image
RUN wget -nv -nc -P /tmp $GH_S6_1 $GH_S6_2 $GH_MT $GH_CL $GH_RE \
 && tar -C / -Jxpf /tmp/${GH_S6_1##*/} \
 && tar -C / -Jxpf /tmp/${GH_S6_2##*/} \
 && tar -C /usr/local/bin -xzf /tmp/${GH_MT##*/} mtail \
 && mkdir -p /etc/mtail/progs \
 && wget -nv -nc -P /etc/mtail/progs $GH_MT_1 \
 && tar -C /usr/local/bin -xzf /tmp/${GH_CL##*/} clamav_exporter \
 && tar -C /usr/local/bin -xzf /tmp/${GH_RE##*/} --strip-component=1 $(basename ${GH_RE%.tar.gz})/redis_exporter \
 && rm /tmp/*
# services
ARG S6_D=/etc/s6-overlay/s6-rc.d
ARG S6_UCD=${S6_D}/user/contents.d
ARG APPS="nginx valkey postfix dovecot rspamd clamd freshclam mtail clamexp redisexp"
ARG SB="#!/command/execlineb -P\n"
RUN mkdir -p ${S6_UCD} \
 && for a in $APPS; do d=${S6_D}/${a}; mkdir -p ${d}; echo "longrun" > ${d}/type; touch ${S6_UCD}/${a} ${d}/run; chmod +x ${d}/run ; done \
 # svc/run files
 && echo -e "${SB}nginx -g \"daemon off;\"" > ${S6_D}/nginx/run \
 && echo -e "${SB}valkey-server /etc/valkey/valkey.conf" > ${S6_D}/valkey/run \
 && echo -e "${SB}postfix start-fg" > ${S6_D}/postfix/run \
 && echo -e "${SB}dovecot -F" > ${S6_D}/dovecot/run \
 && echo -e "${SB}rspamd -f -u rspamd -g rspamd" > ${S6_D}/rspamd/run \
 && echo -e "${SB}clamd --foreground" > ${S6_D}/clamd/run \
 && echo -e "${SB}freshclam -d --foreground" > ${S6_D}/freshclam/run \
 && echo -e "${SB}mtail -progs /etc/mtail/progs/postfix.mtail -logs /var/log/postfix.log" > ${S6_D}/mtail/run \
 && echo -e "${SB}clamav_exporter" > ${S6_D}/clamexp/run \
 && echo -e "${SB}redis_exporter" > ${S6_D}/redisexp/run \
 # tweaks/workarounds
 && sed -i 's/\(listen \[::\]:80\)/# \1/' /etc/nginx/http.d/default.conf \
 && sed -i -E 's/^(worker_processes).+/\1 2;/' /etc/nginx/nginx.conf \
 && a=prepfix d=${S6_D}/${a}; mkdir -p ${d}; echo "oneshot" > ${d}/type; touch ${S6_UCD}/${a} ${d}/up; chmod +x ${d}/up; d2=${S6_D}/postfix/dependencies.d; mkdir -p ${d2}; touch ${d2}/${a} \
 && echo -e "${SB}sh -c \"i=0; until [ -f /etc/postfix/conf.d/conf.sh ]; do i=\$((i+1)); [ \"\$i\" -gt 30 ] && exit 1; sleep 1; done; exec /etc/postfix/conf.d/conf.sh\"" > ${S6_D}/prepfix/up \
 && sed -i -E 's/#+(.+syslog_name.+submission.?)$/\1/' /etc/postfix/master.cf \
 && sed -i -E 's/#+(submission.+smtpd)$/\1/' /etc/postfix/master.cf \
 && sed -i -E 's/#+(.+smtpd_tls_.+encrypt)$/\1/' /etc/postfix/master.cf \
 && sed -i -E 's/#+(.+smtpd_tls_auth_only.+)$/\1/' /etc/postfix/master.cf \
 && sed -i -E 's/#+(.+smtpd_tls_wrappermode.+)$/\1/' /etc/postfix/master.cf \
 && deluser vmail && delgroup vmail || true \
 && addgroup -g 5000 vmail \
 && adduser -D -u 5000 -G vmail -h /mnt/vmail -s /sbin/nologin vmail \
 && a=wireguard d=${S6_D}/${a}; mkdir -p ${d}; echo "oneshot" > ${d}/type; touch ${S6_UCD}/${a} ${d}/up ${d}/down; chmod +x ${d}/up ${d}/down \
 && echo -e "${SB}wg-quick up wg0" > ${S6_D}/wireguard/up \
 && echo -e "${SB}wg-quick down wg0" > ${S6_D}/wireguard/down \
 && mkdir -p -m 0755 /run/clamav && chown clamav:clamav /run/clamav /var/lib/clamav \
 && sed -i -E 's/^(LocalSocket.+sock)/#\1/' /etc/clamav/clamd.conf \
 && sed -i -E 's/^#(TCPSocket.+)/\1/' /etc/clamav/clamd.conf \
 && sed -i -E 's/^#(TCPAddr).+/\1 0.0.0.0/' /etc/clamav/clamd.conf \
 && sed -i -E 's|^#(UpdateLogFile).+|\1 /var/log/clamav/freshclam.log|' /etc/clamav/freshclam.conf \
#  && a=freshclam-init d=${S6_D}/${a}; mkdir -p ${d}; echo "oneshot" > ${d}/type; touch ${S6_UCD}/${a} ${d}/up; chmod +x ${d}/up; d2=${S6_D}/clamd/dependencies.d; mkdir -p ${d2}; touch ${d2}/${a} \
#  && echo -e "${SB}freshclam" > ${S6_D}/freshclam-init/up \
 && echo "added: ${APPS}"
# purely doc purpose for EXPOSE
EXPOSE 80 25 465 587 24 143 993 5451 9900 6379 11332 11333 11334 3310 7357 3903 9906 9121
ENTRYPOINT ["/init"]
