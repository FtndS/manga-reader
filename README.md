# manga-reader (private)

à¸­à¹ˆà¸²à¸™à¸¡à¸±à¸‡à¸‡à¸°/à¸¡à¸±à¸‡à¸®à¸§à¸²à¸ªà¹ˆà¸§à¸™à¸•à¸±à¸§: à¸­à¸±à¸›à¹‚à¸«à¸¥à¸”à¸£à¸¹à¸› â†’ OCR â†’ à¹à¸›à¸¥à¹„à¸—à¸¢ + à¸­à¸±à¸‡à¸à¸¤à¸©

- à¸£à¸±à¸™à¸šà¸™ VPS à¸£à¹ˆà¸§à¸¡ PortDiary (path à¸¥à¸±à¸š + Basic Auth)
- à¸­à¸­à¸à¹à¸šà¸šà¸›à¸£à¸°à¸«à¸¢à¸±à¸” RAM (OCR à¸—à¸µà¸¥à¸°à¸«à¸™à¹‰à¸², mem_limit, LibreTranslate à¹‚à¸«à¸¥à¸”à¹€à¸‰à¸žà¸²à¸°à¸ à¸²à¸©à¸²à¸—à¸µà¹ˆà¹ƒà¸Šà¹‰)

## à¸„à¸§à¸²à¸¡à¸•à¹‰à¸­à¸‡à¸à¸²à¸£à¹€à¸„à¸£à¸·à¹ˆà¸­à¸‡

- RAM ~3.8GB + **Swap 4GB** (à¸ˆà¸³à¹€à¸›à¹‡à¸™)
- Docker + Docker Compose

## à¸—à¸”à¸ªà¸­à¸šà¸šà¸™ PC (local)

\\\powershell
cd D:\manga-reader
copy .env.example .env
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
\\\

à¹€à¸›à¸´à¸” http://localhost:5173

à¸­à¸±à¸›à¹‚à¸«à¸¥à¸” ZIP à¸£à¸¹à¸› à¸«à¸£à¸·à¸­à¸£à¸¹à¸›à¹€à¸”à¸µà¸¢à¸§ à¸£à¸­à¸ªà¸–à¸²à¸™à¸° processing â†’ done

> à¸„à¸£à¸±à¹‰à¸‡à¹à¸£à¸ LibreTranslate / OCR à¸ˆà¸°à¸”à¸²à¸§à¸™à¹Œà¹‚à¸«à¸¥à¸”à¹‚à¸¡à¹€à¸”à¸¥ à¸Šà¹‰à¸²à¹à¸¥à¸°à¸à¸´à¸™ RAM/Swap

à¸•à¸±à¹‰à¸‡à¸ à¸²à¸©à¸²à¸•à¹‰à¸™à¸—à¸²à¸‡à¹ƒà¸™ \.env\:

\\\
OCR_LANGS=korean
\\\

à¸„à¹ˆà¸²à¸—à¸µà¹ˆà¹ƒà¸Šà¹‰à¹„à¸”à¹‰: \korean\ | \japan\ | \chinese\ | \en\

## Push GitHub

\\\powershell
cd D:\manga-reader
git add .
git status
git commit -m "feat: initial manga reader MVP"
git push -u origin main
\\\

## à¸‚à¸¶à¹‰à¸™ VPS

\\\ash
# swap à¸„à¸§à¸£à¸¡à¸µà¹à¸¥à¹‰à¸§
free -h

cd ~
git clone https://github.com/FtndS/manga-reader.git
cd ~/manga-reader
cp .env.example .env
# à¹à¸à¹‰ OCR_LANGS à¸•à¸²à¸¡à¸ à¸²à¸©à¸²à¸—à¸µà¹ˆà¸­à¹ˆà¸²à¸™

# à¸•à¸£à¸§à¸ˆà¸Šà¸·à¹ˆà¸­ network à¸‚à¸­à¸‡ PortDiary
docker network ls | grep portfolio

# à¸–à¹‰à¸²à¸Šà¸·à¹ˆà¸­à¹„à¸¡à¹ˆà¹ƒà¸Šà¹ˆ portfolio-app_portfolio-network à¹ƒà¸«à¹‰à¹à¸à¹‰à¹ƒà¸™ docker-compose.yml

docker compose up -d --build
docker compose ps
\\\

### Basic Auth + path à¸¥à¸±à¸š (à¸œà¸¹à¸ nginx PortDiary)

\\\ash
apt-get install -y apache2-utils
htpasswd -c /root/manga-reader/.htpasswd-reader YOUR_USER
chmod 600 /root/manga-reader/.htpasswd-reader
\\\

à¹ƒà¸™ \~/portfolio-app/nginx.conf\ à¹€à¸žà¸´à¹ˆà¸¡ (à¹€à¸›à¸¥à¸µà¹ˆà¸¢à¸™ SECRET):

\\\
ginx
location /r/YOUR_LONG_SECRET/ {
  auth_basic "private";
  auth_basic_user_file /etc/nginx/.htpasswd-reader;
  proxy_pass http://manga-web:80/;
  client_max_body_size 200m;
}
\\\

à¹ƒà¸™ \docker-compose.yml\ à¸‚à¸­à¸‡ PortDiary à¸à¸±à¹ˆà¸‡ nginx volumes à¹€à¸žà¸´à¹ˆà¸¡:

\\\yaml
- /root/manga-reader/.htpasswd-reader:/etc/nginx/.htpasswd-reader:ro
\\\

à¹à¸¥à¹‰à¸§:

\\\ash
cd ~/portfolio-app
docker compose up -d nginx
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
\\\

à¹€à¸›à¸´à¸”: \https://portdiary.com/r/YOUR_LONG_SECRET/\

## à¸«à¸¡à¸²à¸¢à¹€à¸«à¸•à¸¸

- à¹ƒà¸Šà¹‰à¹„à¸Ÿà¸¥à¹Œà¸—à¸µà¹ˆà¸„à¸¸à¸“à¸¡à¸µà¸ªà¸´à¸—à¸˜à¸´à¹Œà¸­à¹ˆà¸²à¸™à¸ªà¹ˆà¸§à¸™à¸•à¸±à¸§à¹€à¸—à¹ˆà¸²à¸™à¸±à¹‰à¸™
- à¸­à¸¢à¹ˆà¸² commit à¹‚à¸Ÿà¸¥à¹€à¸”à¸­à¸£à¹Œ \data/\ à¸«à¸£à¸·à¸­ \.htpasswd*\
- à¹€à¸¡à¸·à¹ˆà¸­à¹€à¸ªà¸£à¹‡à¸ˆà¹à¸¥à¹‰à¸§à¸„à¸§à¸£à¸•à¸±à¹‰à¸‡ GitHub repo à¸à¸¥à¸±à¸šà¹€à¸›à¹‡à¸™ **private**