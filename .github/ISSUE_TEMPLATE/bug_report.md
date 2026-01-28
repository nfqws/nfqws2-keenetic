---
name: Bug report
about: Create a report to help us improve
title: "[BUG] "
labels: ''
assignees: ''

---

**Опишите проблему**
Подробно опишите что делали и что не работает.

**Модель маршрутизатора**
Укажите полную модель роутера и прошивку

**Провайдер**
Укажите вашего провайдера и тип подключения (ppp/ethernet/...)

**Выполните команды и приложите их вывод**
`opkg info nfqws2-keenetic`
```
<ВСТАВИТЬ СЮДА>
```

`/opt/etc/init.d/S51nfqws2 restart`
```
<ВСТАВИТЬ СЮДА>
```

`cat /opt/etc/nfqws2/nfqws2.conf`
```
<ВСТАВИТЬ СЮДА>
```

`ps | grep nfqws2`
```
<ВСТАВИТЬ СЮДА>
```

`iptables-save | grep 300`
```
<ВСТАВИТЬ СЮДА>
```

`sysctl net.netfilter.nf_conntrack_checksum`
```
<ВСТАВИТЬ СЮДА>
```
