### For testing CORS, you can use the following command:

#### Add example domains in host file

```bash
echo "127.0.0.1    app.example.com" | sudo tee -a /etc/hosts
echo "127.0.0.1    blog.example.com" | sudo tee -a /etc/hosts
echo "127.0.0.1    none.example.com" | sudo tee -a /etc/hosts
```

#### Start html and javascript servers

```bash
python3 -m http.server 3000
```
