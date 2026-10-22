# flash's – estações (backups do flash dos robôs)

Uma pasta por **módulo**; dentro dele, uma pasta por estação (opcional) e uma por robô:

```
flash's/
  Avulso/            robôs soltos
    R11/
    R22/
  VW A/
    6010/            estação
      …_6010_R11/
      …_6010_R12/
```

Cada robô é a cópia do flash do controlador: precisa ter `config/machinedata1.cfg`
(ou `application/control/config/machinedata1.cfg`).

No app: **Download** ▸ Estações ▸ módulo ▸ Baixar (ou *Baixar todos* da estação) ▸ *Abrir na estação*.
