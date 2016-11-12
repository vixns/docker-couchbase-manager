FROM vixns/base
COPY run.sh /run.sh
COPY dig-srv.sh /dig-srv.sh
ENTRYPOINT ["/run.sh"]
