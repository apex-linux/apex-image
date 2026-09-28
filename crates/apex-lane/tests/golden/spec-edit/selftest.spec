Name:           x
Release:        %autorelease
Source0:        x.tar.xz
Patch:          fedora.patch
BuildRequires:  meson
BuildRequires:  mutter-devel >= %{mutter_version}
Requires:       mutter%{?_isa} >= %{mutter_version}
%prep
%autosetup -S git -n x
