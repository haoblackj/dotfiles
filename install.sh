for file in .gitconfig
do
	[ ! -e $file ] && ln -s dotfiles/$file .
done