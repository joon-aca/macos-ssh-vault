# Quick start

## Import your SSH setup (first machine)

```bash
git clone <repo> ~/macos-ssh-vault
cd ~/macos-ssh-vault

./bin/ssh-vault init
./bin/ssh-vault mount
./bin/ssh-vault sync ssh-canonical
./bin/ssh-vault unmount
```

## Deploy on another Mac

```bash
git clone <repo> ~/macos-ssh-vault
cd ~/macos-ssh-vault

./bootstrap ssh-canonical
```

## Push changes back to the vault

```bash
./bin/ssh-vault sync ssh-canonical
```

## Back up

```bash
ssh-vault backup /Volumes/MyDrive/ssh-vault.sparsebundle
```
