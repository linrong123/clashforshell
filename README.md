linux下用的clash脚本，用于快速配置clash，主要解决linux没有gui时clash的配置问题。

# 使用说明
```shell
bash clash.sh
```
# 实现的功能
1. 可以从url下载订阅文件
2. 可以选线路
3. 默认tun模式

# 目录说明
- core: 存放内核相关的文件，现在主要是mihomo、yq、jq
- config: 存放clash的配置文件
- init: 存放自带的一些东西，误删
  - dns.yaml: dns配置文件,用来替换clash的dns配置文件，如有需求可以自行修改，会在程序启动的时候自动替换
  - tun.yaml: tun模式的配置文件，用来替换clash的配置文件，如有需求可以自行修改，会在程序启动的时候自动替换
  - geoip.metadb: geoip数据库文件,可以自行升级替换到~/.config/mihomo/geoip.metadb

# 涉及到内核相关的文件
1. https://github.com/MetaCubeX/mihomo/releases
2. https://github.com/mikefarah/yq/releases
3. https://github.com/jqlang/jq/releases

把以上文件相应的编译二进制版本拷贝到core目录里。命名分别为mihomo-core、yq、jq即可。

本仓库目前带的版本是：
- mihomo-core: v1.18.4
- yq: v4.44.1
- jq: v1.7.1

